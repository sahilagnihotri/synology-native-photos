//! R1-2: a transport failure on any GET path must never put the session id
//! or the SynoToken into the error text. reqwest's error `Display` prints the
//! full request URL, and every GET carries `_sid` in its query (upload also
//! carries `SynoToken`). These errors cross the FFI into Swift, where they are
//! shown and logged.
//!
//! Every call targets `http://127.0.0.1:1`, a closed localhost port, so the
//! request fails at connect and nothing leaves the machine.

use models::{Connection, CoreError, SearchFilters, Space, ThumbnailSize};
use synology_api::transport::Transport;
use synology_api::CollectionFilter;

const SID: &str = "SECRETSID";
const TOKEN: &str = "SECRETTOKEN";

fn dead_transport() -> Transport {
    Transport::new(&Connection {
        host: "http://127.0.0.1:1".to_string(),
        verify_tls: true,
        pinned_cert_der: None,
        allow_untrusted_tls: false,
    })
    .expect("transport builds")
}

fn assert_scrubbed<T: std::fmt::Debug>(what: &str, result: Result<T, CoreError>) {
    let err = match result {
        Ok(v) => panic!("{what}: expected a network error, got Ok({v:?})"),
        Err(e) => e,
    };
    let shown = err.to_string();
    let debugged = format!("{err:?}");
    for text in [&shown, &debugged] {
        assert!(!text.contains(SID), "{what} leaks the sid: {text}");
        assert!(!text.contains(TOKEN), "{what} leaks the SynoToken: {text}");
    }
    assert!(
        matches!(err, CoreError::Network { .. }),
        "{what}: expected Network, got {err:?}"
    );
}

#[tokio::test]
async fn get_paths_never_leak_the_session_in_errors() {
    let t = dead_transport();
    let p = Space::Personal;
    let tok = Some(TOKEN);

    assert_scrubbed(
        "list_items",
        synology_api::list_items(&t, SID, p, 0, 10, 7, tok).await,
    );
    assert_scrubbed(
        "list_items_filtered",
        synology_api::list_items_filtered(&t, SID, CollectionFilter::Favorites, 0, 10, 7, tok)
            .await,
    );
    assert_scrubbed(
        "list_album_items",
        synology_api::list_album_items(&t, SID, p, 1, 0, 10, 7, tok).await,
    );
    assert_scrubbed(
        "filter_items",
        synology_api::filter_items(&t, SID, p, None, None, Some(1), None, 0, 10, 7, tok).await,
    );
    assert_scrubbed(
        "search",
        synology_api::search(&t, SID, "cat", 0, 10, 7, tok).await,
    );
    let filters = SearchFilters {
        start_time: Some(1),
        end_time: None,
    };
    assert_scrubbed(
        "search_filtered",
        synology_api::search_filtered(&t, SID, "cat", &filters, 0, 10, 7, tok).await,
    );
    assert_scrubbed(
        "list_albums",
        synology_api::list_albums(&t, SID, p, 0, 10, 7, tok).await,
    );
    assert_scrubbed(
        "list_people",
        synology_api::list_people(&t, SID, 0, 10, 7, tok).await,
    );
    assert_scrubbed(
        "list_places",
        synology_api::list_places(&t, SID, 0, 10, 7, tok).await,
    );
    assert_scrubbed(
        "list_tags",
        synology_api::list_tags(&t, SID, 0, 10, 7, tok).await,
    );
    assert_scrubbed(
        "list_subjects",
        synology_api::list_subjects(&t, SID, 0, 10, 7, tok).await,
    );
    assert_scrubbed(
        "search_facets",
        synology_api::search_facets(&t, SID, tok).await,
    );
    assert_scrubbed(
        "fetch_thumbnail",
        synology_api::fetch_thumbnail(&t, SID, p, 1, "ck", ThumbnailSize::Sm, 2, tok).await,
    );
    assert_scrubbed(
        "download_original",
        synology_api::download_original(&t, SID, p, 1, "ck", 2, tok).await,
    );
    assert_scrubbed(
        "upload_file",
        synology_api::upload_file(&t, SID, tok, "/home/Photos/Edited", "a.jpg", b"x").await,
    );
    assert_scrubbed(
        "list_recycle_photos",
        synology_api::list_recycle_photos(&t, SID, tok, 0, 10).await,
    );
    assert_scrubbed(
        "recycle_bin_status",
        synology_api::recycle_bin_status(&t, SID, tok).await,
    );
    assert_scrubbed(
        "recycle_thumbnail",
        synology_api::recycle_thumbnail(&t, SID, tok, "/home/#recycle/Photos/a.jpg", "small").await,
    );
    assert_scrubbed(
        "probe_capabilities",
        synology_api::probe_capabilities(&t).await,
    );
}
