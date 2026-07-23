//! HTTP transport for the Synology Web API.
//!
//! Every DSM endpoint we call goes through the single CGI dispatcher at
//! `/webapi/entry.cgi` (verified against the real NAS; NOT `/photo/webapi/...`).
//! This module owns two concerns:
//!
//! 1. TLS trust (section 2.6, locked): global TLS validation is never disabled.
//!    With no pinned cert we use system roots and standard hostname verification
//!    (the DSM's Let's Encrypt cert for `agnihotri.synology.me` validates
//!    normally). With a pinned cert (the Tailscale-IP case, where the cert CN
//!    will not match) we trust exactly that one DER via `add_root_certificate`
//!    and keep hostname verification explicitly on.
//!    `danger_accept_invalid_certs` is never called anywhere in this module.
//! 2. A client-side throttle: Synology's rate limits are undocumented, so we
//!    enforce a minimum gap between outbound requests ourselves rather than
//!    find the real limit by tripping it.

use models::{Connection, CoreError};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// Minimum spacing between outbound requests made through a `Transport`.
const MIN_REQUEST_GAP: Duration = Duration::from_millis(150);

/// The single CGI entry point every `SYNO.*` API call is dispatched through.
pub const ENTRY_CGI_PATH: &str = "/webapi/entry.cgi";

/// Build a reqwest client honoring the locked TLS trust contract (section 2.6).
/// - No pinned cert: system roots, standard verification.
/// - Pinned cert: trust exactly that DER, keep hostname verification ON.
/// - `danger_accept_invalid_certs` is NEVER used.
pub fn build_client(connection: &Connection) -> Result<reqwest::Client, CoreError> {
    let mut builder = reqwest::Client::builder()
        .use_rustls_tls()
        .timeout(Duration::from_secs(30))
        .connect_timeout(Duration::from_secs(10));
    if let Some(der) = &connection.pinned_cert_der {
        let cert = reqwest::Certificate::from_der(der).map_err(|e| CoreError::Network {
            message: format!("pinned certificate is not valid DER: {e}"),
        })?;
        builder = builder.add_root_certificate(cert).danger_accept_invalid_hostnames(false);
    }
    builder.build().map_err(|e| CoreError::Network {
        message: format!("failed to build HTTP client: {e}"),
    })
}

/// Thin wrapper around a reqwest client scoped to one DSM connection: knows
/// the base URL, honors the TLS trust contract, and self-throttles.
pub struct Transport {
    client: reqwest::Client,
    base_url: String,
    last_request: Mutex<Option<Instant>>,
}

impl Transport {
    pub fn new(connection: &Connection) -> Result<Self, CoreError> {
        let client = build_client(connection)?;
        Ok(Self {
            client,
            base_url: connection.host.trim_end_matches('/').to_string(),
            last_request: Mutex::new(None),
        })
    }

    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    pub fn client(&self) -> &reqwest::Client {
        &self.client
    }

    /// Full URL to the shared CGI dispatcher, e.g.
    /// `https://192.168.1.10:5001/webapi/entry.cgi`.
    pub fn entry_url(&self) -> String {
        format!("{}{}", self.base_url, ENTRY_CGI_PATH)
    }

    /// Enforce a minimum gap between outbound requests (rate limits are
    /// undocumented). Callers await this immediately before issuing a
    /// request; it sleeps only as long as needed to satisfy the gap.
    pub async fn throttle(&self) {
        let wait = {
            let mut guard = self.last_request.lock().expect("throttle mutex poisoned");
            let now = Instant::now();
            let wait = match *guard {
                Some(prev) => {
                    let elapsed = now.duration_since(prev);
                    if elapsed < MIN_REQUEST_GAP { MIN_REQUEST_GAP - elapsed } else { Duration::ZERO }
                }
                None => Duration::ZERO,
            };
            *guard = Some(now + wait);
            wait
        };
        if !wait.is_zero() {
            tokio::time::sleep(wait).await;
        }
    }

    /// POST a form-encoded request to the shared CGI dispatcher and decode
    /// the Synology envelope into `T`. Applies the throttle before sending.
    pub async fn post_form<T: serde::de::DeserializeOwned>(
        &self,
        form: &[(&str, &str)],
    ) -> Result<T, CoreError> {
        self.throttle().await;
        let response = self
            .client
            .post(self.entry_url())
            .form(form)
            .send()
            .await
            .map_err(|e| CoreError::Network { message: format!("request failed: {e}") })?;
        let body = response
            .text()
            .await
            .map_err(|e| CoreError::Network { message: format!("failed to read response body: {e}") })?;
        crate::envelope::decode_envelope(&body)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use models::Connection;

    fn conn(host: &str, pinned: Option<Vec<u8>>) -> Connection {
        Connection { host: host.to_string(), verify_tls: true, pinned_cert_der: pinned }
    }

    #[test]
    fn builds_client_with_system_roots_when_no_pin() {
        assert!(build_client(&conn("https://192.168.1.10:5001", None)).is_ok());
    }

    #[test]
    fn rejects_bad_pinned_cert() {
        let err = build_client(&conn("https://nas.ts.net:5001", Some(vec![0x00, 0x01, 0x02]))).unwrap_err();
        assert!(matches!(err, models::CoreError::Network { .. }), "got {err:?}");
    }

    #[test]
    fn transport_exposes_base_url() {
        let t = Transport::new(&conn("https://192.168.1.10:5001", None)).expect("transport builds");
        assert_eq!(t.base_url(), "https://192.168.1.10:5001");
    }

    #[tokio::test]
    async fn throttle_enforces_minimum_gap() {
        let t = Transport::new(&conn("https://192.168.1.10:5001", None)).expect("transport builds");
        let start = std::time::Instant::now();
        t.throttle().await;
        t.throttle().await;
        assert!(start.elapsed() >= std::time::Duration::from_millis(140),
                "second throttle should enforce the inter-request gap");
    }

    #[derive(Debug, serde::Deserialize, PartialEq)]
    struct Probe {
        sid: String,
    }

    #[tokio::test]
    async fn post_form_hits_entry_cgi_and_decodes_envelope() {
        let mut server = mockito::Server::new_async().await;
        let mock = server
            .mock("POST", "/webapi/entry.cgi")
            .match_header("content-type", mockito::Matcher::Regex("application/x-www-form-urlencoded".into()))
            .match_body(mockito::Matcher::AllOf(vec![
                mockito::Matcher::Regex("api=SYNO.API.Auth".into()),
                mockito::Matcher::Regex("method=login".into()),
            ]))
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(r#"{"success":true,"data":{"sid":"SID123"}}"#)
            .create_async()
            .await;

        let t = Transport::new(&conn(&server.url(), None)).expect("transport builds");
        let got: Probe = t
            .post_form(&[("api", "SYNO.API.Auth"), ("method", "login")])
            .await
            .expect("mocked request should decode");

        assert_eq!(got, Probe { sid: "SID123".to_string() });
        mock.assert_async().await;
    }

    #[tokio::test]
    async fn post_form_maps_envelope_error_to_core_error() {
        let mut server = mockito::Server::new_async().await;
        server
            .mock("POST", "/webapi/entry.cgi")
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(r#"{"success":false,"error":{"code":400}}"#)
            .create_async()
            .await;

        let t = Transport::new(&conn(&server.url(), None)).expect("transport builds");
        let err = t
            .post_form::<Probe>(&[("api", "SYNO.API.Auth"), ("method", "login")])
            .await
            .unwrap_err();

        assert!(matches!(err, models::CoreError::Auth { .. }), "got {err:?}");
    }
}
