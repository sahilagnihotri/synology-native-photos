#[test]
fn crate_builds_with_deps() {
    let _client = reqwest::Client::builder()
        .use_rustls_tls()
        .build()
        .expect("rustls client builds");
    assert!(!synology_api::VERSION.is_empty());
}
