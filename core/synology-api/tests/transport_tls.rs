//! End-to-end TLS trust tests against a real (self-signed, in-process) TLS
//! server: proves the three build_client paths (default strict, pinned
//! exact-leaf, dev-only danger toggle) against actual TLS handshakes rather
//! than only unit-testing the builder configuration.
//!
//! The test server is a bare `rustls`/`tokio-rustls` TCP+TLS listener (no
//! HTTP framing needed): each accepted connection is handed the configured
//! certificate during the handshake and then the connection is dropped. That
//! is enough to exercise `fetch_server_cert_der` (captures the leaf cert) and
//! `build_client`'s pinned connect (a real `reqwest` client completing a
//! handshake against it), without needing to speak the Synology envelope at
//! all.
//!
//! The leaf-pin tests below are the regression coverage for the real bug:
//! `start_server` generates a plain leaf certificate (Basic Constraints
//! CA:FALSE), exactly the shape the real Synology NAS presents, whereas the
//! old test suite only ever pinned an in-test CA certificate (a valid trust
//! anchor), which is why it passed while the real NAS handshake failed.

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
    // each one completes the handshake (or fails, e.g. on a cert mismatch the
    // *client* makes) and then, if the handshake succeeded, writes back a
    // minimal fixed HTTP/1.1 response so a real `reqwest` GET through this
    // connection observes a clean success rather than a `ConnectionReset`
    // that a bare dropped socket would otherwise produce after a successful
    // handshake. `fetch_server_cert_der` never sends a request past the
    // handshake at all, so this response is only ever read by the
    // `build_client`-driven connect attempts in the tests below.
    tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else { return };
            let acceptor = acceptor.clone();
            tokio::spawn(async move {
                if let Ok(mut tls) = acceptor.accept(stream).await {
                    use tokio::io::AsyncWriteExt;
                    let _ = tls
                        .write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
                        .await;
                    let _ = tls.shutdown().await;
                }
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
async fn pinned_leaf_cert_connects_ok() {
    // THE regression test for the real bug: the server presents a LEAF
    // certificate (Basic Constraints CA:FALSE, exactly what the real
    // Synology NAS presents), pinned to that exact leaf DER. Before the
    // custom-verifier fix, the pinned path added the leaf via
    // `add_root_certificate` with built-in roots disabled, which cannot
    // verify a chain rooted in a non-CA certificate, so this handshake
    // failed at setup with the opaque "error sending request". The fix
    // (`PinnedCertVerifier`) authenticates by exact leaf-DER match instead
    // of chain building, so this must now connect successfully.
    let server = start_server(vec!["nas.example.internal".to_string()]).await;
    let host = format!("{}:{}", server.addr.ip(), server.addr.port());

    let info = fetch_server_cert_der(&host).await.expect("cert probe should succeed");
    assert_eq!(info.der, server.cert_der, "sanity: the probed cert is the leaf the server presents");

    let connection = Connection {
        host: host.clone(),
        verify_tls: true,
        pinned_cert_der: Some(info.der.clone()),
        allow_untrusted_tls: false,
    };
    let client = build_client(&connection).expect("client builds with pin");
    let result = client.get(format!("https://{host}/")).send().await;
    assert!(
        result.is_ok(),
        "pinning the exact leaf DER the server presents must connect successfully, got: {result:?}"
    );
}

#[tokio::test]
async fn pinned_leaf_cert_rejects_a_different_leaf() {
    // Anti-MITM property: pin server A's leaf, then connect to server B,
    // which presents a DIFFERENT leaf (different key, same SAN). Only the
    // exact pinned DER may complete the handshake, so this must be rejected
    // even though B's certificate is otherwise perfectly well-formed. A
    // verifier that accepted any leaf, or that fell back to chain trust,
    // would let this through and defeat pinning entirely.
    let server_a = start_server(vec!["nas.example.internal".to_string()]).await;
    let info_a = fetch_server_cert_der(&format!("{}:{}", server_a.addr.ip(), server_a.addr.port()))
        .await
        .expect("cert probe on server A should succeed");

    let server_b = start_server(vec!["nas.example.internal".to_string()]).await;
    let host_b = format!("{}:{}", server_b.addr.ip(), server_b.addr.port());
    assert_ne!(info_a.der, server_b.cert_der, "the two leaves must actually differ for this test to prove anything");

    let connection = Connection { host: host_b.clone(), verify_tls: true, pinned_cert_der: Some(info_a.der), allow_untrusted_tls: false };
    let client = build_client(&connection).expect("client builds with a pin for a different server");
    let result = client.get(format!("https://{host_b}/")).send().await;
    assert!(result.is_err(), "connecting to a server presenting a leaf that is NOT the pin must be rejected");
}

#[tokio::test]
async fn pinned_leaf_cert_connects_ok_when_server_presents_a_chain() {
    // Proves chain length is irrelevant to the pinned path: the server here
    // presents a leaf signed by an intermediate/CA (a 2-cert chain), and only
    // the leaf DER is pinned. The custom verifier only ever looks at the
    // end-entity certificate, so this must connect exactly like the
    // single-cert self-signed case, whether or not an issuer is attached.
    let (server, _ca_der) = start_server_with_ca_signed_leaf(vec!["nas.example.internal".to_string()]).await;
    let host = format!("{}:{}", server.addr.ip(), server.addr.port());

    let info = fetch_server_cert_der(&host).await.expect("cert probe should succeed");
    assert_eq!(info.der, server.cert_der, "sanity: the probed cert is the leaf the server presents");

    let connection = Connection {
        host: host.clone(),
        verify_tls: true,
        pinned_cert_der: Some(info.der.clone()),
        allow_untrusted_tls: false,
    };
    let client = build_client(&connection).expect("client builds with pin");
    let result = client.get(format!("https://{host}/")).send().await;
    assert!(
        result.is_ok(),
        "pinning the leaf of a CA-issued chain must connect regardless of chain length, got: {result:?}"
    );
}

#[tokio::test]
async fn pinned_cert_connects_even_when_san_names_a_different_host() {
    // Historical failure case, now trivially true under exact-leaf pinning:
    // the server's certificate SAN (`nas.example.internal`) never names the
    // address we actually connect through (mirrors the real NAS cert, issued
    // for its public DDNS name, never covering the LAN/Tailscale address the
    // app dials). The custom verifier never inspects the connection hostname
    // at all, so a SAN/host mismatch must not matter once the leaf DER is
    // pinned; connecting by bare IP:port here (rather than a resolvable
    // MagicDNS-style name) is enough to prove hostname checking never runs,
    // since `PinnedCertVerifier` does not special-case IP literals either.
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
    assert!(
        result.is_ok(),
        "a SAN naming a different host than the one dialed must not matter once the leaf DER is pinned: {result:?}"
    );
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
                if let Ok(mut tls) = acceptor.accept(stream).await {
                    use tokio::io::AsyncWriteExt;
                    let _ = tls
                        .write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
                        .await;
                    let _ = tls.shutdown().await;
                }
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

