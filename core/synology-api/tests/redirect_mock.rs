//! R1-1: the HTTP client must never follow a redirect. A 307 or 308 replays
//! the POST body (password, OTP, `_sid`) and the `X-SYNO-TOKEN` header to
//! whatever host `Location` names. Every test here uses two localhost mock
//! servers: the "NAS" that answers with a redirect and an "evil" server that
//! must receive nothing.

use models::{Connection, CoreError, Space};
use synology_api::transport::Transport;

fn transport_for(server: &mockito::ServerGuard) -> Transport {
    Transport::new(&Connection {
        host: server.url(),
        verify_tls: true,
        pinned_cert_der: None,
        allow_untrusted_tls: false,
    })
    .expect("transport builds")
}

async fn redirecting_nas(status: usize, evil: &mockito::ServerGuard) -> mockito::ServerGuard {
    let mut nas = mockito::Server::new_async().await;
    nas.mock("POST", "/webapi/entry.cgi")
        .match_query(mockito::Matcher::Any)
        .with_status(status)
        .with_header("Location", &format!("{}/steal", evil.url()))
        .create_async()
        .await;
    nas.mock("GET", "/webapi/entry.cgi")
        .match_query(mockito::Matcher::Any)
        .with_status(status)
        .with_header("Location", &format!("{}/steal", evil.url()))
        .create_async()
        .await;
    nas
}

/// Traps for both methods: a 301 or 302 turns a POST into a GET, while a
/// 307 or 308 keeps the POST. Either reaching the evil server is a leak.
struct Trap(Vec<mockito::Mock>);

impl Trap {
    async fn assert_async(&self) {
        for m in &self.0 {
            m.assert_async().await;
        }
    }
}

async fn evil_trap(evil: &mut mockito::ServerGuard) -> Trap {
    let mut mocks = Vec::new();
    for method in ["POST", "GET"] {
        mocks.push(
            evil.mock(method, mockito::Matcher::Any)
                .match_query(mockito::Matcher::Any)
                .with_status(200)
                .with_body(r#"{"success":true,"data":{"sid":"EVIL"}}"#)
                .expect(0)
                .create_async()
                .await,
        );
    }
    Trap(mocks)
}

#[tokio::test]
async fn login_does_not_follow_a_307_to_another_origin() {
    let mut evil = mockito::Server::new_async().await;
    let trap = evil_trap(&mut evil).await;
    let nas = redirecting_nas(307, &evil).await;
    let t = transport_for(&nas);
    let result = synology_api::login(&t, "photouser", "hunter2", Some("123456"), None).await;
    assert!(
        result.is_err(),
        "login must fail on a redirect, got {result:?}"
    );
    let msg = result.unwrap_err().to_string();
    assert!(
        msg.contains("redirect"),
        "error should name the redirect: {msg}"
    );
    assert!(
        !msg.contains("hunter2"),
        "error must not echo the password: {msg}"
    );
    trap.assert_async().await;
}

#[tokio::test]
async fn permanent_delete_does_not_follow_a_308_to_another_origin() {
    let mut evil = mockito::Server::new_async().await;
    let trap = evil_trap(&mut evil).await;
    let nas = redirecting_nas(308, &evil).await;
    let t = transport_for(&nas);
    let result =
        synology_api::permanent_delete(&t, "SECRETSID", Space::Personal, &[1], 7, Some("TOK"))
            .await;
    assert!(
        matches!(result, Err(CoreError::Network { .. })),
        "delete must fail on a redirect, got {result:?}"
    );
    trap.assert_async().await;
}

#[tokio::test]
async fn browse_get_does_not_follow_a_302_to_another_origin() {
    let mut evil = mockito::Server::new_async().await;
    let trap = evil_trap(&mut evil).await;
    let nas = redirecting_nas(302, &evil).await;
    let t = transport_for(&nas);
    let result = synology_api::download_original(
        &t,
        "SECRETSID",
        Space::Personal,
        101,
        "ck",
        2,
        Some("TOK"),
    )
    .await;
    assert!(result.is_err(), "download must fail on a redirect");
    trap.assert_async().await;
}

/// The pinned client is built through the same builder, but its TLS config
/// is replaced wholesale, so prove the redirect refusal survives on that path
/// too. A self-signed localhost TLS server answers every request with a 307
/// to a plain localhost listener, which must see no connection at all.
#[tokio::test]
async fn pinned_client_does_not_follow_a_redirect() {
    use rustls_pki_types::{CertificateDer, PrivateKeyDer};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let evil = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let evil_addr = evil.local_addr().unwrap();
    let evil_hits = Arc::new(AtomicUsize::new(0));
    let hits = evil_hits.clone();
    tokio::spawn(async move {
        while let Ok((_s, _)) = evil.accept().await {
            hits.fetch_add(1, Ordering::SeqCst);
        }
    });

    let rcgen::CertifiedKey { cert, signing_key } =
        rcgen::generate_simple_self_signed(vec!["127.0.0.1".to_string()]).unwrap();
    let cert_der = cert.der().to_vec();
    let server_config = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(
            vec![CertificateDer::from(cert_der.clone())],
            PrivateKeyDer::try_from(signing_key.serialize_der()).unwrap(),
        )
        .unwrap();
    let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(server_config));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let response = format!(
        "HTTP/1.1 307 Temporary Redirect\r\nlocation: http://{evil_addr}/steal\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
    );
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            let acceptor = acceptor.clone();
            let response = response.clone();
            tokio::spawn(async move {
                if let Ok(mut tls) = acceptor.accept(stream).await {
                    let mut buf = [0u8; 4096];
                    let _ = tls.read(&mut buf).await;
                    let _ = tls.write_all(response.as_bytes()).await;
                    let _ = tls.shutdown().await;
                }
            });
        }
    });

    let t = Transport::new(&Connection {
        host: format!("https://{}:{}", addr.ip(), addr.port()),
        verify_tls: true,
        pinned_cert_der: Some(cert_der),
        allow_untrusted_tls: false,
    })
    .expect("pinned transport builds");
    let result =
        synology_api::permanent_delete(&t, "SECRETSID", Space::Personal, &[1], 7, Some("TOK"))
            .await;
    assert!(
        matches!(result, Err(CoreError::Network { .. })),
        "pinned delete must fail on a redirect, got {result:?}"
    );
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    assert_eq!(
        evil_hits.load(Ordering::SeqCst),
        0,
        "redirect target was contacted"
    );
}
