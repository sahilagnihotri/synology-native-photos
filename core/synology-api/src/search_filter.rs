//! `SYNO.Foto.Search.Filter`, `method=list`: the facet catalog behind
//! Synology's advanced search (camera, aperture, geocoding tree, media
//! type, and several other facets DSM exposes for display but that have no
//! working filter param -- see the module doc below and `models::Facet`'s
//! doc comment for the full probe transcript).
//!
//! VERIFIED against the real NAS (versions 1-4 all return the identical
//! payload; this module sends version 1): the full response shape is
//! `{"aperture":[{id,name}], "camera":[{id,name}], "exposure_time_group":
//! [{start:{num,den},end:{num,den}}], "favorite":[], "flash":[int],
//! "focal_length_group":[{start,end}], "folder_filter":[{id,name,...}],
//! "general_tag":[], "geocoding":[{id,level,name,children:[...]}] (a
//! nested tree, walked flat by `flatten_geocoding` below), "iso":
//! [{id,name}], "item_type":[{id,name}] (this account only ever reports
//! `{"id":0,"name":"photo"}`), "lens":[{id,name}], "person":[], "rating":
//! [int], "time":[{year,month,start_time,end_time}]}`.
//!
//! Of all of these, ONLY `camera`, `aperture`, `geocoding`, and `item_type`
//! are modeled here (as `SearchFacets`), because they are the ones the
//! brief and the real UI need to show; every other facet
//! (`exposure_time_group`, `flash`, `focal_length_group`, `folder_filter`,
//! `general_tag`, `iso`, `lens`, `person`, `rating`, `time`) is dropped on
//! the floor, both because they had no working `Search.Search` filter
//! param either (not exhaustively re-probed, but `general_tag`/`person`
//! are already known-empty on this account, and DSM's own preset `time`
//! buckets are superseded by the free `start_time`/`end_time` range that
//! IS confirmed working) and because the brief scopes this feature to
//! Camera/Date/Location/Media-type/Aperture.
//!
//! IMPORTANT (see `models::Facet`'s doc comment for the full probe
//! transcript): `camera`, `aperture`, and `geocoding` are listed correctly
//! here, but NEITHER `Search.Search list_item` NOR `Browse.Item` accepts a
//! working filter param for camera/aperture on this NAS (a real id and a
//! bogus id returned byte-identical unfiltered results for `camera_id`,
//! `aperture_id`, `geocoding_id`, `item_type`, and several JSON-blob
//! shapes). So `search_facets` still returns them for the UI to browse/
//! label, but `synology_api::browse::search` has no corresponding filter
//! param to send for camera/aperture/media-type; only the date range
//! (`start_time`/`end_time`) is wired as a real filter.

use crate::envelope::decode_envelope;
use crate::transport::Transport;
use models::{CoreError, Facet, SearchFacets};
use serde::Deserialize;

const SEARCH_FILTER_API: &str = "SYNO.Foto.Search.Filter";

#[derive(Debug, Deserialize, Default)]
struct RawSearchFilter {
    #[serde(default)]
    camera: Vec<RawFacet>,
    #[serde(default)]
    aperture: Vec<RawFacet>,
    #[serde(default)]
    geocoding: Vec<RawGeocodingNode>,
    #[serde(default)]
    item_type: Vec<RawFacet>,
}

#[derive(Debug, Deserialize)]
struct RawFacet {
    id: i64,
    #[serde(default)]
    name: Option<String>,
}

/// One geocoding tree node. VERIFIED against the real NAS: `children` can
/// nest several levels deep (country -> region -> city -> district); every
/// node at every depth carries its own usable `id`/`name`, so
/// `flatten_geocoding` below walks the whole tree rather than only the top
/// level, producing one flat list a caller can search/pick from regardless
/// of depth.
#[derive(Debug, Deserialize)]
struct RawGeocodingNode {
    id: i64,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    children: Vec<RawGeocodingNode>,
}

/// Walks a geocoding tree (any depth) into one flat `Vec<Facet>`, parent
/// nodes included alongside their children (a caller may want to filter by
/// "Norway" as a whole, not only by "Grunerlokka, Oslo"). Order is
/// depth-first, parent before its children, matching the order DSM itself
/// returns the tree in.
fn flatten_geocoding(nodes: &[RawGeocodingNode], out: &mut Vec<Facet>) {
    for node in nodes {
        out.push(Facet {
            id: node.id,
            name: node.name.clone().unwrap_or_else(|| node.id.to_string()),
        });
        flatten_geocoding(&node.children, out);
    }
}

fn to_facets(raw: &[RawFacet]) -> Vec<Facet> {
    raw.iter()
        .map(|f| Facet { id: f.id, name: f.name.clone().unwrap_or_else(|| f.id.to_string()) })
        .collect()
}

/// Issue a GET against the shared entry.cgi dispatcher and return the raw
/// response body. Same token discipline as every other module in this
/// crate: `X-SYNO-TOKEN` sent when `syno_token` is `Some`, omitted (never
/// sent empty) when `None`.
async fn get_body(transport: &Transport, query: &[(&str, String)], syno_token: Option<&str>) -> Result<String, CoreError> {
    transport.throttle().await;
    let query_refs: Vec<(&str, &str)> = query.iter().map(|(k, v)| (*k, v.as_str())).collect();
    let mut request = transport.client().get(transport.entry_url()).query(&query_refs);
    if let Some(token) = syno_token {
        request = request.header("X-SYNO-TOKEN", token);
    }
    let response = request
        .send()
        .await
        .map_err(|e| CoreError::Network { message: format!("search filter request failed: {e}") })?;
    response
        .text()
        .await
        .map_err(|e| CoreError::Network { message: format!("reading search filter response body failed: {e}") })
}

/// `SYNO.Foto.Search.Filter`, `method=list`, version 1 (versions 1-4 were
/// confirmed identical against the real NAS, so there is no need to pin a
/// higher one). Personal space only: this API was only probed under
/// `SYNO.Foto.*`, never `SYNO.FotoTeam.*`.
///
/// Decoding is tolerant: every field defaults to empty on absence/mismatch
/// rather than failing the whole catalog, matching the rest of this crate's
/// discipline. A `Facet`/geocoding node missing only its `name` still
/// produces a usable entry (falls back to the id) rather than being
/// dropped.
pub async fn search_facets(
    transport: &Transport,
    sid: &str,
    syno_token: Option<&str>,
) -> Result<SearchFacets, CoreError> {
    let query: Vec<(&str, String)> = vec![
        ("api", SEARCH_FILTER_API.to_string()),
        ("version", "1".to_string()),
        ("method", "list".to_string()),
        ("_sid", sid.to_string()),
    ];
    let body = get_body(transport, &query, syno_token).await?;
    let parsed: RawSearchFilter = decode_envelope(&body)?;
    let mut geocodings = Vec::new();
    flatten_geocoding(&parsed.geocoding, &mut geocodings);
    Ok(SearchFacets {
        cameras: to_facets(&parsed.camera),
        apertures: to_facets(&parsed.aperture),
        geocodings,
        media_types: to_facets(&parsed.item_type),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flattens_nested_geocoding_tree_depth_first() {
        let tree = vec![RawGeocodingNode {
            id: 1,
            name: Some("Norway".to_string()),
            children: vec![RawGeocodingNode {
                id: 12,
                name: Some("Oslo".to_string()),
                children: vec![RawGeocodingNode { id: 50, name: Some("Grunerlokka".to_string()), children: vec![] }],
            }],
        }];
        let mut out = Vec::new();
        flatten_geocoding(&tree, &mut out);
        assert_eq!(out.len(), 3);
        assert_eq!(out[0], Facet { id: 1, name: "Norway".to_string() });
        assert_eq!(out[1], Facet { id: 12, name: "Oslo".to_string() });
        assert_eq!(out[2], Facet { id: 50, name: "Grunerlokka".to_string() });
    }

    #[test]
    fn missing_name_falls_back_to_id() {
        let raw = vec![RawFacet { id: 99, name: None }];
        let facets = to_facets(&raw);
        assert_eq!(facets, vec![Facet { id: 99, name: "99".to_string() }]);
    }
}
