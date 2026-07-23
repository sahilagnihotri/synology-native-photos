//! SYNO.API.Info capability probe, tested against the real-shape fixture
//! captured on the user's own NAS (see documentation/phase0-probe-results.md).
//!
//! Note the probe hits `/webapi/query.cgi`, a sibling of the shared
//! `/webapi/entry.cgi` dispatcher used by every other API in this crate,
//! not `/photo/webapi/query.cgi`. This was confirmed against the real NAS:
//! `SYNO.API.Info` itself reports `path: "entry.cgi"` for every API it
//! describes, but the Info query itself is issued at `/webapi/query.cgi`.

use models::{ApiCapability, Connection, CoreError};
use synology_api::info::{pin_version, probe_capabilities};
use synology_api::transport::Transport;

fn transport_for(server: &mockito::ServerGuard) -> Transport {
    Transport::new(&Connection { host: server.url(), verify_tls: true, pinned_cert_der: None })
        .expect("transport builds")
}

/// Real response shape captured against the user's own NAS: every API in
/// SYNO.Foto.* land is served through path "entry.cgi", and versions drift
/// per API (Thumbnail tops out at 2 while the browse APIs go to 7).
const REAL_SHAPE_FIXTURE: &str = r#"{"success":true,"data":{
    "SYNO.API.Auth":{"minVersion":1,"maxVersion":7,"path":"entry.cgi"},
    "SYNO.Foto.Browse.Item":{"minVersion":1,"maxVersion":7,"path":"entry.cgi","requestFormat":"JSON"},
    "SYNO.Foto.Thumbnail":{"minVersion":1,"maxVersion":2,"path":"entry.cgi","requestFormat":"JSON"},
    "SYNO.FotoTeam.Browse.Item":{"minVersion":1,"maxVersion":7,"path":"entry.cgi","requestFormat":"JSON"}
}}"#;

#[tokio::test]
async fn probe_parses_real_shape_fixture_into_capabilities() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/query.cgi")
        .match_query(mockito::Matcher::Any)
        .with_status(200)
        .with_body(REAL_SHAPE_FIXTURE)
        .create_async()
        .await;
    let t = transport_for(&server);
    let mut caps = probe_capabilities(&t).await.expect("probe ok");
    caps.sort_by(|a, b| a.name.cmp(&b.name));

    assert_eq!(caps.len(), 4);

    let auth = caps.iter().find(|c| c.name == "SYNO.API.Auth").unwrap();
    assert_eq!(auth.path, "entry.cgi");
    assert_eq!(auth.min_version, 1);
    assert_eq!(auth.max_version, 7);

    let item = caps.iter().find(|c| c.name == "SYNO.Foto.Browse.Item").unwrap();
    assert_eq!(item.path, "entry.cgi");
    assert_eq!(item.min_version, 1);
    assert_eq!(item.max_version, 7);

    // The real NAS advertises a narrower window for Thumbnail than the
    // browse APIs; the probe must preserve that per-API window exactly.
    let thumb = caps.iter().find(|c| c.name == "SYNO.Foto.Thumbnail").unwrap();
    assert_eq!(thumb.path, "entry.cgi");
    assert_eq!(thumb.min_version, 1);
    assert_eq!(thumb.max_version, 2);

    let team_item = caps.iter().find(|c| c.name == "SYNO.FotoTeam.Browse.Item").unwrap();
    assert_eq!(team_item.min_version, 1);
    assert_eq!(team_item.max_version, 7);
}

#[tokio::test]
async fn probe_ignores_unknown_extra_fields_per_api() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/query.cgi")
        .match_query(mockito::Matcher::Any)
        .with_status(200)
        .with_body(
            r#"{"success":true,"data":{
                "SYNO.Foto.Browse.Item":{
                    "minVersion":1,"maxVersion":4,"path":"entry.cgi",
                    "requestFormat":"JSON","future":"ignored","nested":{"a":1}
                }
            }}"#,
        )
        .create_async()
        .await;
    let t = transport_for(&server);
    let caps = probe_capabilities(&t).await.expect("unknown fields must not break decode");
    assert_eq!(caps.len(), 1);
    assert_eq!(caps[0].name, "SYNO.Foto.Browse.Item");
    assert_eq!(caps[0].max_version, 4);
}

#[test]
fn pin_version_clamps_into_range() {
    let caps = vec![ApiCapability {
        name: "SYNO.Foto.Browse.Item".into(),
        path: "entry.cgi".into(),
        min_version: 2,
        max_version: 4,
    }];
    assert_eq!(pin_version(&caps, "SYNO.Foto.Browse.Item", 3).unwrap(), 3);
    assert_eq!(pin_version(&caps, "SYNO.Foto.Browse.Item", 9).unwrap(), 4);
    assert_eq!(pin_version(&caps, "SYNO.Foto.Browse.Item", 1).unwrap(), 2);
}

#[test]
fn pin_version_clamps_thumbnail_desired_seven_down_to_real_max_two() {
    // Matches the real NAS: every other Foto API advertises maxVersion 7,
    // but Thumbnail tops out at 2. A client requesting the "usual" version
    // 7 must be pinned down to 2, not sent unclamped.
    let caps = vec![ApiCapability {
        name: "SYNO.Foto.Thumbnail".into(),
        path: "entry.cgi".into(),
        min_version: 1,
        max_version: 2,
    }];
    assert_eq!(pin_version(&caps, "SYNO.Foto.Thumbnail", 7).unwrap(), 2);
}

#[test]
fn pin_version_missing_api_is_capability_unavailable() {
    let caps: Vec<ApiCapability> = vec![];
    let err = pin_version(&caps, "SYNO.Foto.Thumbnail", 2).unwrap_err();
    assert!(
        matches!(err, CoreError::CapabilityUnavailable { ref api } if api == "SYNO.Foto.Thumbnail"),
        "got {err:?}"
    );
}
