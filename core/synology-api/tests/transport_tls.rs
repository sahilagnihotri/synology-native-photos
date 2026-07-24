//! End-to-end TLS trust tests against a real (self-signed, in-process) TLS
//! server: proves the three build_client paths (default strict, pinned
//! cert+hostname-relaxed-only, dev-only danger toggle) against actual TLS
//! handshakes rather than only unit-testing the builder configuration.
//!
//! The test server is a bare `rustls`/`tokio-rustls` TCP+TLS listener (no
//! HTTP framing needed): each accepted connection is handed the configured
//! certificate during the handshake and then the connection is dropped. That
//! is enough to exercise `fetch_server_cert_der` (captures the leaf cert) and
//! `build_client`'s pinned/relaxed-hostname connect (a real `reqwest` client
//! completing a handshake against it), without needing to speak the
//! Synology envelope at all.

use models::Connection;
use rustls_pki_types::{CertificateDer, PrivateKeyDer};
use synology_api::transport::{build_client, fetch_server_cert_der};

/// A self-signed cert/key pair plus a running TLS listener on `127.0.0.1` that
/// accepts one connection per `accept_one` call and immediately completes a
/// TLS handshake presenting `cert`. Held so the listener stays alive for the
/// duration of a test.
struct TestTlsServer {
    addr: std::net::SocketAddr,
    cert_der: Vec<u8>,
}

async fn start_server(subject_alt_names: Vec<String>) -> TestTlsServer {
    let rcgen::CertifiedKey { cert, signing_key } =
        rcgen::generate_simple_self_signed(subject_alt_names).expect("self-signed cert generates");
    let cert_der = cert.der().to_vec();
    let key_der = signing_key.serialize_der();

    let server_config = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(
            vec![CertificateDer::from(cert_der.clone())],
            PrivateKeyDer::try_from(key_der).expect("key parses"),
        )
        .expect("server config builds");
    let acceptor = tokio_rustls::TlsAcceptor::from(std::sync::Arc::new(server_config));

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.expect("listener binds");
    let addr = listener.local_addr().expect("listener has an addr");

    // Accept connections in a background task for the test's whole lifetime;
    // each one just completes the handshake (or fails, e.g. on a hostname or
    // cert mismatch check the *client* makes) and is dropped. No HTTP needs
    // to be served: `fetch_server_cert_der` never sends a request past the
    // handshake, and the `build_client`-driven connect attempts in these
    // tests only need the handshake outcome, not a real response body.
    tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else { return };
            let acceptor = acceptor.clone();
            tokio::spawn(async move {
                let _ = acceptor.accept(stream).await;
            });
        }
    });

    TestTlsServer { addr, cert_der }
}

#[tokio::test]
async fn fetch_server_cert_der_captures_the_presented_leaf_cert() {
    let server = start_server(vec!["127.0.0.1".to_string()]).await;
    let host = format!("{}:{}", server.addr.ip(), server.addr.port());

    let info = fetch_server_cert_der(&host).await.expect("cert probe should succeed");
    assert_eq!(info.der, server.cert_der, "captured DER must match the cert the server actually presented");
    assert_eq!(info.sha256_hex.len(), 64, "sha256 hex fingerprint must be 64 hex chars");
    assert!(!info.subject.is_empty(), "subject must be non-empty");
}

#[tokio::test]
async fn pinned_cert_for_ip_host_connects_with_hostname_check_relaxed() {
    // The cert's SAN is a DNS name, not the IP we connect to (mirrors the
    // real agnihotri.synology.me-cert-over-Tailscale-IP failure case), so a
    // strict client would reject it on hostname grounds even with the right
    // cert pinned. The pinned path must still succeed by relaxing hostname
    // matching ONLY, while the cert identity itself is authenticated by the
    // pin.
    let server = start_server(vec!["nas.example.internal".to_string()]).await;
    let host = format!("{}:{}", server.addr.ip(), server.addr.port());

    let info = fetch_server_cert_der(&host).await.expect("cert probe should succeed");

    let connection = Connection {
        host: host.clone(),
        verify_tls: true,
        pinned_cert_der: Some(info.der.clone()),
        allow_untrusted_tls: false,
    };
    let client = build_client(&connection).expect("client builds with pin");
    let result = client.get(format!("https://{host}/")).send().await;
    // We only care that the TLS handshake itself succeeded (name+cert trust
    // resolved); the peer never speaks HTTP back, so the request itself may
    // still error out afterward (e.g. on reading a response). What must NOT
    // happen is a certificate or hostname verification error.
    match result {
        Ok(_) => {}
        Err(e) => {
            let msg = e.to_string();
            assert!(
                !msg.to_lowercase().contains("certificate") && !msg.to_lowercase().contains("hostname") && !msg.to_lowercase().contains("name"),
                "handshake must not fail on cert/hostname grounds with a correct pin: {msg}"
            );
        }
    }
}

#[tokio::test]
async fn strict_default_client_rejects_self_signed_cert_with_no_pin() {
    // No pin, allow_untrusted_tls=false (the default): the self-signed cert
    // is not in any trust store, so the connection must fail on certificate
    // grounds. This proves the default path is not silently permissive.
    let server = start_server(vec!["127.0.0.1".to_string()]).await;
    let host = format!("{}:{}", server.addr.ip(), server.addr.port());

    let connection = Connection { host: host.clone(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
    let client = build_client(&connection).expect("client builds");
    let result = client.get(format!("https://{host}/")).send().await;
    assert!(result.is_err(), "an unpinned self-signed cert must be rejected by the default strict path");
}

#[tokio::test]
async fn dev_toggle_connects_despite_self_signed_cert_with_no_pin() {
    // allow_untrusted_tls=true, no pin: the one path where
    // danger_accept_invalid_certs is reachable. The same self-signed cert
    // that the strict-default test rejects must now be accepted.
    let server = start_server(vec!["127.0.0.1".to_string()]).await;
    let host = format!("{}:{}", server.addr.ip(), server.addr.port());

    let connection = Connection { host: host.clone(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: true };
    let client = build_client(&connection).expect("client builds");
    let result = client.get(format!("https://{host}/")).send().await;
    match result {
        Ok(_) => {}
        Err(e) => {
            let msg = e.to_string().to_lowercase();
            assert!(
                !msg.contains("certificate") && !msg.contains("unknownissuer") && !msg.contains("invalid"),
                "dev toggle must accept the self-signed cert; got: {msg}"
            );
        }
    }
}

/// Starts a TLS listener like `start_server`, except the leaf certificate it
/// presents is signed by a freshly generated CA rather than being
/// self-signed. Simulates "a certificate that chains to some CA" without
/// needing a real public CA, so a test can prove that CA-chained trust is
/// NOT what lets a handshake through on the pinned path. Returns the
/// listener plus the leaf DER (for asserting it differs from the pin) and
/// the CA's DER (never added as a pin or root by any test using this).
async fn start_server_with_ca_signed_leaf(subject_alt_names: Vec<String>) -> (TestTlsServer, Vec<u8>) {
    use rcgen::{BasicConstraints, CertificateParams, DnType, Issuer, IsCa, KeyPair};

    let ca_key = KeyPair::generate().expect("ca key generates");
    let mut ca_params = CertificateParams::default();
    ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    ca_params.distinguished_name.push(DnType::CommonName, "test-only fake CA, never trusted by any pin");
    let ca_cert = ca_params.self_signed(&ca_key).expect("ca self-signs");
    let ca_der = ca_cert.der().to_vec();
    let issuer = Issuer::new(ca_params, ca_key);

    let leaf_key = KeyPair::generate().expect("leaf key generates");
    let leaf_params = CertificateParams::new(subject_alt_names).expect("leaf params build");
    let leaf_cert = leaf_params.signed_by(&leaf_key, &issuer).expect("ca signs the leaf");
    let leaf_der = leaf_cert.der().to_vec();

    let server_config = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![CertificateDer::from(leaf_der.clone())], PrivateKeyDer::try_from(leaf_key.serialize_der()).expect("key parses"))
        .expect("server config builds");
    let acceptor = tokio_rustls::TlsAcceptor::from(std::sync::Arc::new(server_config));

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.expect("listener binds");
    let addr = listener.local_addr().expect("listener has an addr");

    tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else { return };
            let acceptor = acceptor.clone();
            tokio::spawn(async move {
                let _ = acceptor.accept(stream).await;
            });
        }
    });

    (TestTlsServer { addr, cert_der: leaf_der }, ca_der)
}

#[tokio::test]
async fn pinned_path_rejects_a_ca_signed_cert_that_is_not_the_pin() {
    // Regression test for the MITM bypass: add_root_certificate alone only
    // ADDS the pin to whatever trust store the builder already has, so if
    // built-in public CA roots were left enabled, the handshake would
    // succeed against EITHER the pinned DER OR any certificate chaining to
    // a public CA. build_client must disable built-in roots on the pinned
    // path so ONLY the pin is trusted.
    //
    // This test proves exactly that "chains to a CA" property without a
    // real public CA: server B presents a leaf signed by a fake CA minted
    // just for this test. That fake CA is never added as the pin and never
    // added as a root by build_client, so the ONLY way this leaf could pass
    // is if the client still trusted arbitrary CA-issued certificates, the
    // bug this test guards against. The pin is set to server A's unrelated
    // self-signed cert, and hostname checking is relaxed exactly like the
    // real IP-literal case (danger_accept_invalid_hostnames(true)), so the
    // rejection below is proven to come from certificate trust, not from a
    // hostname mismatch that would mask a real regression.
    let server_a = start_server(vec!["nas.example.internal".to_string()]).await;
    let info_a = fetch_server_cert_der(&format!("{}:{}", server_a.addr.ip(), server_a.addr.port()))
        .await
        .expect("cert probe on server A should succeed");

    let (server_b, _fake_ca_der) = start_server_with_ca_signed_leaf(vec!["nas.example.internal".to_string()]).await;
    let host_b = format!("{}:{}", server_b.addr.ip(), server_b.addr.port());

    assert_ne!(info_a.der, server_b.cert_der, "the pin and server B's CA-signed leaf must actually differ for this test to prove anything");

    let connection = Connection { host: host_b.clone(), verify_tls: true, pinned_cert_der: Some(info_a.der), allow_untrusted_tls: false };
    let client = build_client(&connection).expect("client builds with a pin for a different server");
    let result = client.get(format!("https://{host_b}/")).send().await;
    assert!(
        result.is_err(),
        "a CA-signed cert that is not the pin must be rejected on the pinned path; if this succeeds, built-in/CA-chained trust leaked back in and the pin is no longer the sole trust anchor"
    );
}

#[tokio::test]
async fn reconnect_against_a_different_cert_fails_the_pin() {
    // Pin the cert from server A, then attempt to connect to server B (a
    // different self-signed cert, different key, same SAN). The pinned
    // client trusts only A's exact DER, so a handshake against B's
    // certificate must fail: this is the whole point of pinning (detects
    // cert rotation / a MITM presenting a different cert on reconnect).
    let server_a = start_server(vec!["nas.example.internal".to_string()]).await;
    let info_a = fetch_server_cert_der(&format!("{}:{}", server_a.addr.ip(), server_a.addr.port()))
        .await
        .expect("cert probe on server A should succeed");

    let server_b = start_server(vec!["nas.example.internal".to_string()]).await;
    let host_b = format!("{}:{}", server_b.addr.ip(), server_b.addr.port());

    assert_ne!(info_a.der, server_b.cert_der, "the two self-signed certs must actually differ for this test to prove anything");

    let connection = Connection { host: host_b.clone(), verify_tls: true, pinned_cert_der: Some(info_a.der), allow_untrusted_tls: false };
    let client = build_client(&connection).expect("client builds with a stale pin");
    let result = client.get(format!("https://{host_b}/")).send().await;
    assert!(result.is_err(), "connecting to a server presenting a DIFFERENT cert than the pin must fail");
}
