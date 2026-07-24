//! HTTP transport for the Synology Web API.
//!
//! Every DSM endpoint we call goes through the single CGI dispatcher at
//! `/webapi/entry.cgi` (verified against the real NAS; NOT `/photo/webapi/...`).
//! This module owns three concerns:
//!
//! 1. Host normalization: turning whatever the user typed into `Connection.host`
//!    (a bare IP, a bare hostname, an explicit scheme/port, an IPv6 literal, a
//!    trailing slash) into a well-formed base URL. See `normalize_host`.
//! 2. TLS trust, in three strictly separated paths (see `build_client`):
//!      - Default (no pin, `allow_untrusted_tls == false`): system roots,
//!        standard hostname verification. `danger_accept_invalid_certs` is
//!        never reachable on this path.
//!      - Pinned (`pinned_cert_der` is `Some`): the pinned DER is trusted via
//!        `add_root_certificate`. Hostname verification stays ON unless the
//!        connection host is a bare IP literal, in which case ONLY hostname
//!        matching is relaxed (`danger_accept_invalid_hostnames(true)`). The
//!        certificate itself is still fully authenticated against the pin.
//!        `danger_accept_invalid_certs` is never called on this path either.
//!      - Dev toggle (`allow_untrusted_tls == true` AND no usable pin): the
//!        one and only path that calls `danger_accept_invalid_certs(true)`.
//!        This is insecure by design (see `Connection::allow_untrusted_tls`)
//!        and exists purely as a last-resort, explicit opt-in.
//! 3. A client-side throttle: Synology's rate limits are undocumented, so we
//!    enforce a minimum gap between outbound requests ourselves rather than
//!    find the real limit by tripping it.

use models::{CertInfo, Connection, CoreError};
use std::net::IpAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Minimum spacing between outbound requests made through a `Transport`.
const MIN_REQUEST_GAP: Duration = Duration::from_millis(150);

/// The single CGI entry point every `SYNO.*` API call is dispatched through.
pub const ENTRY_CGI_PATH: &str = "/webapi/entry.cgi";

/// Default DSM HTTPS port used when `Connection.host` specifies neither an
/// explicit scheme nor an explicit port.
const DEFAULT_PORT: &str = "5001";

/// Normalize a user-supplied host into a well-formed base URL (no trailing
/// slash, no path).
///
/// Rules:
/// - No scheme present -> prepend `https://`.
/// - An explicit scheme (`http://` or `https://`) is left alone.
/// - No explicit port present -> append `:5001` (the DSM default). A port is
///   considered present only if it comes after the host part, so an IPv6
///   literal's internal colons never get mistaken for a port separator.
/// - An explicit port is left alone.
/// - IPv6 literals must be (and remain) bracketed, e.g. `[::1]` / `[::1]:5001`.
/// - Any trailing `/` (or run of them) is trimmed.
///
/// This is pure string logic (no DNS lookups, no I/O) so it is cheap to call
/// on every `Transport::new` and easy to unit test exhaustively.
pub fn normalize_host(host: &str) -> String {
    let trimmed = host.trim();
    let (scheme, rest) = split_scheme(trimmed);
    let rest = rest.trim_end_matches('/');
    let with_port = ensure_port(rest);
    format!("{scheme}://{with_port}")
}

/// Splits an explicit `scheme://` prefix off `host`, defaulting to `https`
/// when none is present. Returns `(scheme, remainder)`; `remainder` never
/// contains a scheme prefix.
fn split_scheme(host: &str) -> (&'static str, &str) {
    if let Some(rest) = host.strip_prefix("https://") {
        ("https", rest)
    } else if let Some(rest) = host.strip_prefix("http://") {
        ("http", rest)
    } else {
        ("https", host)
    }
}

/// Appends the default DSM port (`:5001`) to `host_and_maybe_port` if it does
/// not already specify one. Handles bracketed IPv6 literals (`[::1]`,
/// `[::1]:5001`) so the address's own colons are never mistaken for a port
/// separator, and plain hostnames/IPv4 addresses (`host`, `host:1234`).
fn ensure_port(host_and_maybe_port: &str) -> String {
    if let Some(after_bracket) = host_and_maybe_port.strip_prefix('[') {
        // IPv6 literal: `[addr]` or `[addr]:port`.
        return match after_bracket.split_once(']') {
            Some((addr, rest)) if rest.starts_with(':') && rest.len() > 1 => {
                format!("[{addr}]{rest}")
            }
            Some((addr, _)) => format!("[{addr}]:{DEFAULT_PORT}"),
            // Malformed (no closing bracket): pass through unchanged rather
            // than guessing at a repair.
            None => host_and_maybe_port.to_string(),
        };
    }
    // An unbracketed IPv6 literal (e.g. `::1`, `fe80::1`) contains more than
    // one colon and no digits-only suffix after the last one that would make
    // sense as a port; bracket it and recurse so the branch above handles it
    // uniformly. A host:port pair (`192.168.1.10:8001`, `nas.example.com:8001`)
    // has exactly one colon, so this never misfires on those.
    if host_and_maybe_port.matches(':').count() > 1 && host_and_maybe_port.parse::<IpAddr>().is_ok() {
        return ensure_port(&format!("[{host_and_maybe_port}]"));
    }
    // Plain hostname or IPv4 literal: a port is present only if there is a
    // colon *after* the host part. IPv4/hostnames never contain a colon
    // themselves, so a single split on the last colon is unambiguous here.
    match host_and_maybe_port.rsplit_once(':') {
        Some((_, port)) if !port.is_empty() && port.chars().all(|c| c.is_ascii_digit()) => {
            host_and_maybe_port.to_string()
        }
        _ => format!("{host_and_maybe_port}:{DEFAULT_PORT}"),
    }
}

/// True if `host` (the bare host part of a normalized base URL, e.g.
/// `192.168.1.10` or `[::1]`) is an IP literal rather than a DNS name. Used
/// by `build_client` to decide whether the pinned path needs to relax
/// hostname verification: a cert minted for a DNS name will never validate
/// against an IP literal even though the pin proves it is the right server.
fn host_is_ip_literal(host: &str) -> bool {
    let unbracketed = host.strip_prefix('[').and_then(|s| s.strip_suffix(']')).unwrap_or(host);
    unbracketed.parse::<IpAddr>().is_ok()
}

/// Extracts the bare host (no scheme, no port, brackets stripped for IPv6)
/// from a normalized `scheme://host:port` base URL, for TLS trust decisions.
fn bare_host(base_url: &str) -> &str {
    let (_, rest) = split_scheme(base_url);
    if let Some(after_bracket) = rest.strip_prefix('[') {
        if let Some((addr, _)) = after_bracket.split_once(']') {
            return addr;
        }
    }
    rest.rsplit_once(':').map(|(h, _)| h).unwrap_or(rest)
}

/// Build a reqwest client per the three-way TLS trust contract documented at
/// the top of this module:
/// - No pin, `allow_untrusted_tls == false` (the default): system roots,
///   standard verification, fully strict.
/// - Pin present: the pinned DER is the sole trust anchor via
///   `add_root_certificate`; hostname verification is relaxed ONLY when the
///   connection host is a bare IP literal (never for a DNS name), and even
///   then only the name check is skipped. The certificate itself is still
///   authenticated against the pin.
/// - No pin, `allow_untrusted_tls == true`: the one dev-only path that calls
///   `danger_accept_invalid_certs(true)`. See the loud warning on
///   `Connection::allow_untrusted_tls`.
///
/// A pin always takes precedence over `allow_untrusted_tls`: if both are set,
/// the pinned path runs and the insecure toggle is ignored, so a real pin can
/// never be silently downgraded to "accept anything" by a leftover dev flag.
pub fn build_client(connection: &Connection) -> Result<reqwest::Client, CoreError> {
    let mut builder = reqwest::Client::builder()
        .use_rustls_tls()
        .timeout(Duration::from_secs(30))
        .connect_timeout(Duration::from_secs(10));

    if let Some(der) = &connection.pinned_cert_der {
        let cert = reqwest::Certificate::from_der(der).map_err(|e| CoreError::Network {
            message: format!("pinned certificate is not valid DER: {e}"),
        })?;
        let base_url = normalize_host(&connection.host);
        let relax_hostname = host_is_ip_literal(bare_host(&base_url));
        builder = builder.add_root_certificate(cert).danger_accept_invalid_hostnames(relax_hostname);
    } else if connection.allow_untrusted_tls {
        // DEV-ONLY, INSECURE: accepts any certificate from any server. Only
        // reachable when there is no pin at all; see the doc comment on
        // `Connection::allow_untrusted_tls`.
        builder = builder.danger_accept_invalid_certs(true);
    }

    builder.build().map_err(|e| CoreError::Network {
        message: format!("failed to build HTTP client: {e}"),
    })
}

/// Fetches the DER bytes of the TLS certificate presented by `host` (a raw
/// `Connection.host`-shaped string; normalized internally the same way
/// `Transport::new` does), along with its SHA-256 fingerprint (lowercase hex)
/// and a human-readable subject string, for trust-on-first-use approval.
///
/// This performs a real TLS handshake but with certificate validation
/// disabled. That relaxation is scoped ENTIRELY to this one-shot probe
/// connection, which is dropped immediately after the handshake and never
/// reused for any data request. No plaintext HTTP request is ever sent; the
/// only bytes exchanged are the TLS handshake itself, which we abort as soon
/// as the server's certificate chain has been captured.
///
/// Callers (`PhotosCore::fetch_certificate`) are expected to show the
/// fingerprint + subject to the user, who approves once; only then is the
/// DER persisted into `Connection.pinned_cert_der`. This function itself
/// makes no trust decision at all: it can never be used to talk to the NAS,
/// only to look at what certificate it presents.
pub async fn fetch_server_cert_der(host: &str) -> Result<CertInfo, CoreError> {
    let base_url = normalize_host(host);
    let target_host = bare_host(&base_url).to_string();
    let port = base_url
        .rsplit_once(':')
        .map(|(_, p)| p)
        .and_then(|p| p.parse::<u16>().ok())
        .unwrap_or(5001);

    let captured: Arc<Mutex<Option<Vec<u8>>>> = Arc::new(Mutex::new(None));
    let verifier = CapturingVerifier { captured: captured.clone() };

    let mut config = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(verifier))
        .with_no_client_auth();
    config.alpn_protocols = vec![b"http/1.1".to_vec()];

    let connector = tokio_rustls::TlsConnector::from(Arc::new(config));
    let server_name = rustls_pki_types::ServerName::try_from(target_host.clone())
        .or_else(|_| {
            // Bracket-stripped IP literal: ServerName also accepts a bare IP
            // string, but `target_host` may still be missing brackets that
            // were already stripped by `bare_host`; try the raw parse too.
            target_host
                .parse::<IpAddr>()
                .map(rustls_pki_types::ServerName::from)
                .map_err(|_| CoreError::Network { message: format!("invalid host for TLS probe: {target_host}") })
        })?;

    let tcp = tokio::net::TcpStream::connect((target_host.as_str(), port))
        .await
        .map_err(|e| CoreError::Network { message: format!("could not connect to {target_host}:{port} to read its certificate: {e}") })?;

    // We only need the handshake to complete far enough to receive the
    // server's certificate chain; a verifier-triggered rejection or a
    // connection error after that point is fine and expected (no HTTP
    // request is ever sent over this connection).
    let _ = connector.connect(server_name, tcp).await;

    let der = captured
        .lock()
        .expect("cert capture mutex poisoned")
        .take()
        .ok_or_else(|| CoreError::Network {
            message: format!("server at {target_host}:{port} did not present a certificate"),
        })?;

    let sha256_hex = sha256_hex(&der);
    let subject = subject_of(&der);

    Ok(CertInfo { der, sha256_hex, subject })
}

/// Hex-encodes the SHA-256 digest of `der`, for display as a TOFU fingerprint.
fn sha256_hex(der: &[u8]) -> String {
    use sha2::Digest;
    let digest = sha2::Sha256::digest(der);
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

/// Best-effort human-readable subject (e.g. `CN=agnihotri.synology.me`) for
/// display alongside the fingerprint. Never fails the TOFU flow: if the
/// certificate cannot be parsed for some reason, a placeholder string is
/// returned instead of an error, because the fingerprint alone is still a
/// valid (if less friendly) basis for the user's approval decision.
fn subject_of(der: &[u8]) -> String {
    match x509_parser::parse_x509_certificate(der) {
        Ok((_, cert)) => cert.subject().to_string(),
        Err(_) => "<unparsed certificate subject>".to_string(),
    }
}

/// A `rustls` certificate verifier that accepts absolutely any certificate
/// chain, but first copies the leaf certificate's DER bytes out to
/// `captured`. This is deliberately, narrowly insecure: it exists ONLY
/// inside `fetch_server_cert_der`'s throwaway probe connection, which sends
/// no application data and is dropped immediately after the handshake. It
/// must never be used to build a client for real requests. `build_client`
/// never references this type.
#[derive(Debug)]
struct CapturingVerifier {
    captured: Arc<Mutex<Option<Vec<u8>>>>,
}

impl rustls::client::danger::ServerCertVerifier for CapturingVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &rustls_pki_types::CertificateDer<'_>,
        _intermediates: &[rustls_pki_types::CertificateDer<'_>],
        _server_name: &rustls_pki_types::ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls_pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        *self.captured.lock().expect("cert capture mutex poisoned") = Some(end_entity.as_ref().to_vec());
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &rustls_pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &rustls_pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        // Accept every scheme rustls knows about: this verifier never
        // actually checks a signature (see the two methods above), it only
        // needs to not reject the handshake before the certificate is
        // captured.
        vec![
            rustls::SignatureScheme::RSA_PKCS1_SHA1,
            rustls::SignatureScheme::ECDSA_SHA1_Legacy,
            rustls::SignatureScheme::RSA_PKCS1_SHA256,
            rustls::SignatureScheme::ECDSA_NISTP256_SHA256,
            rustls::SignatureScheme::RSA_PKCS1_SHA384,
            rustls::SignatureScheme::ECDSA_NISTP384_SHA384,
            rustls::SignatureScheme::RSA_PKCS1_SHA512,
            rustls::SignatureScheme::ECDSA_NISTP521_SHA512,
            rustls::SignatureScheme::RSA_PSS_SHA256,
            rustls::SignatureScheme::RSA_PSS_SHA384,
            rustls::SignatureScheme::RSA_PSS_SHA512,
            rustls::SignatureScheme::ED25519,
        ]
    }
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
            base_url: normalize_host(&connection.host),
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
    ///
    /// Every caller that sends sensitive parameters (a password, an OTP
    /// code, a device token) MUST use this rather than a query-string GET:
    /// form-body params never appear in a URL, a proxy log line, or a
    /// `reqwest::Error`'s `Display` output the way a query string would.
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
            .map_err(scrub_reqwest_error)?;
        let body = response
            .text()
            .await
            .map_err(scrub_reqwest_error)?;
        crate::envelope::decode_envelope(&body)
    }
}

/// Converts a `reqwest::Error` into `CoreError::Network` WITHOUT ever
/// including the request URL (`reqwest::Error::without_url` strips it) or any
/// other request detail. `reqwest::Error`'s `Display` never includes body
/// content or header values, only the URL and a short error-kind
/// description, so stripping the URL is sufficient to guarantee no
/// credential (password, OTP code, device token, session id), all of which
/// travel in the body or as query values, never in the fixed path this
/// strips down to, can leak through an error message.
fn scrub_reqwest_error(e: reqwest::Error) -> CoreError {
    CoreError::Network { message: format!("request failed: {}", e.without_url()) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use models::Connection;

    fn conn(host: &str, pinned: Option<Vec<u8>>) -> Connection {
        Connection { host: host.to_string(), verify_tls: true, pinned_cert_der: pinned, allow_untrusted_tls: false }
    }

    // --- Section A: host normalization -------------------------------

    #[test]
    fn bare_ipv4_gets_https_and_default_port() {
        assert_eq!(normalize_host("192.168.1.10"), "https://192.168.1.10:5001");
    }

    #[test]
    fn bare_ipv4_with_trailing_slash_is_trimmed() {
        assert_eq!(normalize_host("192.168.1.10/"), "https://192.168.1.10:5001");
        assert_eq!(normalize_host("192.168.1.10//"), "https://192.168.1.10:5001");
    }

    #[test]
    fn explicit_host_and_port_is_kept() {
        assert_eq!(normalize_host("192.168.1.10:8001"), "https://192.168.1.10:8001");
        assert_eq!(normalize_host("https://192.168.1.10:8001"), "https://192.168.1.10:8001");
    }

    #[test]
    fn explicit_http_scheme_is_kept_not_upgraded() {
        assert_eq!(normalize_host("http://192.168.1.10"), "http://192.168.1.10:5001");
        assert_eq!(normalize_host("http://192.168.1.10:5000"), "http://192.168.1.10:5000");
    }

    #[test]
    fn explicit_https_scheme_with_no_port_still_gets_default_port() {
        assert_eq!(normalize_host("https://nas.example.com"), "https://nas.example.com:5001");
    }

    #[test]
    fn ipv6_literal_gets_bracketed_default_port() {
        assert_eq!(normalize_host("[::1]"), "https://[::1]:5001");
        assert_eq!(normalize_host("::1"), "https://[::1]:5001", "unbracketed IPv6 must be bracketed");
    }

    #[test]
    fn ipv6_literal_with_explicit_port_is_kept() {
        assert_eq!(normalize_host("[::1]:8001"), "https://[::1]:8001");
        assert_eq!(normalize_host("https://[fe80::1]:5001/"), "https://[fe80::1]:5001");
    }

    #[test]
    fn hostname_only_gets_https_and_default_port() {
        assert_eq!(normalize_host("nas.example.com"), "https://nas.example.com:5001");
    }

    #[test]
    fn tailscale_ip_from_the_real_failure_case_normalizes_cleanly() {
        // The exact host string that previously failed to parse as a URL at
        // all ("builder error").
        assert_eq!(normalize_host("100.87.107.5"), "https://100.87.107.5:5001");
    }

    #[test]
    fn whitespace_is_trimmed() {
        assert_eq!(normalize_host("  192.168.1.10  "), "https://192.168.1.10:5001");
    }

    // --- Section B/C: build_client TLS paths --------------------------

    #[test]
    fn builds_client_with_system_roots_when_no_pin_and_no_dev_toggle() {
        assert!(build_client(&conn("https://192.168.1.10:5001", None)).is_ok());
    }

    #[test]
    fn rejects_bad_pinned_cert() {
        let err = build_client(&conn("https://nas.ts.net:5001", Some(vec![0x00, 0x01, 0x02]))).unwrap_err();
        assert!(matches!(err, models::CoreError::Network { .. }), "got {err:?}");
    }

    #[test]
    fn dev_toggle_alone_still_builds_a_client() {
        // allow_untrusted_tls=true with no pin takes the dev-only path; this
        // only proves the builder succeeds, the actual "does it skip cert
        // validation" behavior is exercised end-to-end in transport_dev tests.
        let mut c = conn("https://192.168.1.10:5001", None);
        c.allow_untrusted_tls = true;
        assert!(build_client(&c).is_ok());
    }

    #[test]
    fn pin_present_takes_precedence_over_dev_toggle() {
        // A real DER is not needed here: this only proves build_client does
        // not error out when both fields are set. The safety property (pin
        // wins, danger_accept_invalid_certs never called) is structural in
        // build_client's if/else and is exercised against a live TLS server
        // in the transport_tls integration test.
        let mut c = conn("https://nas.ts.net:5001", Some(vec![0x00, 0x01]));
        c.allow_untrusted_tls = true;
        let err = build_client(&c).unwrap_err();
        // The dummy DER above is not valid DER, so this still errors, but on
        // the "bad pinned cert" path, proving the pinned branch (not the
        // dev-toggle branch) was taken even though allow_untrusted_tls=true.
        assert!(matches!(err, models::CoreError::Network { .. }), "got {err:?}");
    }

    #[test]
    fn transport_exposes_base_url() {
        let t = Transport::new(&conn("https://192.168.1.10:5001", None)).expect("transport builds");
        assert_eq!(t.base_url(), "https://192.168.1.10:5001");
    }

    #[test]
    fn transport_normalizes_bare_host() {
        let t = Transport::new(&conn("192.168.1.10", None)).expect("transport builds");
        assert_eq!(t.base_url(), "https://192.168.1.10:5001");
    }

    #[test]
    fn host_is_ip_literal_detects_ipv4_and_ipv6_not_hostnames() {
        assert!(host_is_ip_literal("192.168.1.10"));
        assert!(host_is_ip_literal("[::1]"));
        assert!(host_is_ip_literal("100.87.107.5"));
        assert!(!host_is_ip_literal("agnihotri.synology.me"));
        assert!(!host_is_ip_literal("nas.example.com"));
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

    #[tokio::test]
    async fn post_form_network_error_never_includes_url() {
        // Point at a host nothing is listening on so the request fails at
        // the transport level (not a decoded envelope), then assert the
        // resulting CoreError::Network message contains neither the host
        // nor any URL fragment.
        let t = Transport::new(&conn("https://127.0.0.1:1", None)).expect("transport builds");
        let err = t
            .post_form::<Probe>(&[("api", "SYNO.API.Auth"), ("method", "login"), ("passwd", "s3cr3t-password")])
            .await
            .unwrap_err();
        let message = err.to_string();
        assert!(!message.contains("127.0.0.1"), "error must not leak the host: {message}");
        assert!(!message.contains("s3cr3t-password"), "error must not leak form params: {message}");
    }
}
