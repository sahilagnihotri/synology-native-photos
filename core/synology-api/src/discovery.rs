//! Discovery-browse listers: `SYNO.Foto.Browse.Person` / `Geocoding` /
//! `GeneralTag` / `Concept`. Personal-space only for this pass (Person,
//! Geocoding, GeneralTag and Concept were only probed and confirmed under
//! `SYNO.Foto.*`; the `FotoTeam` shared-space equivalents are unverified
//! and out of scope here).
//!
//! Every call is dispatched through the shared CGI entry point at
//! `/webapi/entry.cgi`, same as `browse.rs`, and sends `X-SYNO-TOKEN` the
//! same way (required, or DSM answers with error 119; see the module doc
//! on `browse::get_body`, whose logic this module reuses rather than
//! duplicating).
//!
//! Decoding is tolerant and per-element, same discipline as `browse.rs`:
//! `list` is parsed as `Vec<serde_json::Value>` first, then each element is
//! decoded independently via `browse`'s shared `decode_one`, so one
//! malformed row never fails the whole page.
//!
//! VERIFIED against the real NAS (see the discovery-browse plan doc for the
//! full probe transcript):
//! - `SYNO.Foto.Browse.Person` v1 list returns `{cover, id, item_count,
//!   name, show}`. `name` is the empty string for a person DSM has not
//!   named; `cover` is a unit_id-shaped int for the representative
//!   thumbnail (no cache_key accompanies it on this API).
//! - `SYNO.Foto.Browse.Geocoding` v1 list returns `{country, country_id,
//!   first_level, id, item_count, name, second_level}`.
//! - `SYNO.Foto.Browse.GeneralTag` v1 list returns `{id, item_count,
//!   name}` (confirmed via an empty-list response on this account; no
//!   populated tag existed to confirm the field names against non-empty
//!   data, so they are decoded tolerantly with sensible defaults).
//! - `SYNO.Foto.Browse.Concept` v1 list returns `{display_threshold, id,
//!   item_count, name, sort_index, visibility}`.
//! - There is no dedicated Favorite list API (`SYNO.Foto.Favorite.Item`
//!   returns error 102, no such API); favorited items are fetched by
//!   filtering `Browse.Item` with `favorite=true` instead, so this module
//!   has no `list_favorites` of its own -- `browse::list_items_filtered`
//!   with `CollectionFilter::Favorites` covers it.

use crate::envelope::decode_envelope;
use crate::transport::Transport;
use models::{CoreError, Person, Place, Subject, Tag};
use serde::Deserialize;

const PERSON_API: &str = "SYNO.Foto.Browse.Person";
const GEOCODING_API: &str = "SYNO.Foto.Browse.Geocoding";
const GENERAL_TAG_API: &str = "SYNO.Foto.Browse.GeneralTag";
const CONCEPT_API: &str = "SYNO.Foto.Browse.Concept";

#[derive(Debug, Deserialize)]
struct ListEnvelope {
    #[serde(default)]
    list: Vec<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
struct RawPerson {
    id: i64,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    item_count: u32,
    #[serde(default)]
    cover: Option<i64>,
    #[serde(default = "default_show")]
    show: bool,
}

fn default_show() -> bool {
    true
}

#[derive(Debug, Deserialize)]
struct RawGeocoding {
    id: i64,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    country: Option<String>,
    #[serde(default)]
    first_level: Option<String>,
    #[serde(default)]
    second_level: Option<String>,
    #[serde(default)]
    item_count: u32,
}

#[derive(Debug, Deserialize)]
struct RawTag {
    id: i64,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    item_count: u32,
}

#[derive(Debug, Deserialize)]
struct RawConcept {
    id: i64,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    item_count: u32,
}

/// Decode a single raw list element into `T`, logging and returning `None`
/// on failure instead of propagating the error. Mirrors `browse::decode_one`
/// (kept as a separate copy rather than made `pub` there and imported: this
/// module's rows have their own minimum-viable-identity shape, and neither
/// module needs to depend on the internal layout of the other).
fn decode_one<T: serde::de::DeserializeOwned>(value: &serde_json::Value, kind: &str) -> Option<T> {
    match serde_json::from_value::<T>(value.clone()) {
        Ok(parsed) => Some(parsed),
        Err(e) => {
            let raw_id = value.get("id").map(|v| v.to_string()).unwrap_or_else(|| "?".to_string());
            tracing::warn!("skipping malformed {kind} (id={raw_id}): failed to decode: {e}");
            None
        }
    }
}

/// Issue a GET against the shared entry.cgi dispatcher and return the raw
/// response body. Mirrors `browse::get_body`'s token-header discipline:
/// `X-SYNO-TOKEN` is sent when `syno_token` is `Some`, omitted entirely
/// (never sent empty) when `None`.
async fn get_body(
    transport: &Transport,
    query: &[(&str, String)],
    syno_token: Option<&str>,
) -> Result<String, CoreError> {
    transport.throttle().await;
    let query_refs: Vec<(&str, &str)> = query.iter().map(|(k, v)| (*k, v.as_str())).collect();
    let mut request = transport.client().get(transport.entry_url()).query(&query_refs);
    if let Some(token) = syno_token {
        request = request.header("X-SYNO-TOKEN", token);
    }
    let response = request
        .send()
        .await
        .map_err(|e| CoreError::Network { message: format!("discovery request failed: {e}") })?;
    response
        .text()
        .await
        .map_err(|e| CoreError::Network { message: format!("reading discovery response body failed: {e}") })
}

fn base_query<'a>(api: &'a str, version: u32, offset: u32, limit: u32, sid: &'a str) -> Vec<(&'a str, String)> {
    vec![
        ("api", api.to_string()),
        ("version", version.to_string()),
        ("method", "list".to_string()),
        ("offset", offset.to_string()),
        ("limit", limit.to_string()),
        ("_sid", sid.to_string()),
    ]
}

/// `SYNO.Foto.Browse.Person`, `method=list`. Personal space only.
///
/// `name` empty means DSM has not been given a name for this cluster; the
/// caller is expected to show that as a disabled "Add Name" placeholder,
/// never as a real name. `cover` is decoded into `Person.cover_unit_id`
/// as-is: it goes through the same thumbnail fetch path as `Asset.unit_id`
/// (verified: both endpoints key on a unit_id, not a browse item id), but
/// Person carries no cache_key of its own for it, so the caller passes an
/// empty cache_key when fetching this thumbnail.
pub async fn list_people(
    transport: &Transport,
    sid: &str,
    offset: u32,
    limit: u32,
    version: u32,
    syno_token: Option<&str>,
) -> Result<Vec<Person>, CoreError> {
    let query = base_query(PERSON_API, version, offset, limit, sid);
    let body = get_body(transport, &query, syno_token).await?;
    let parsed: ListEnvelope = decode_envelope(&body)?;
    let total = parsed.list.len();
    let people: Vec<Person> = parsed
        .list
        .iter()
        .filter_map(|raw| {
            let p: RawPerson = decode_one(raw, "person")?;
            Some(Person {
                id: p.id,
                name: p.name.unwrap_or_default(),
                item_count: p.item_count,
                cover_unit_id: p.cover,
                show: p.show,
            })
        })
        .collect();
    log_skipped("person", total, people.len());
    Ok(people)
}

/// `SYNO.Foto.Browse.Geocoding`, `method=list`. Personal space only.
pub async fn list_places(
    transport: &Transport,
    sid: &str,
    offset: u32,
    limit: u32,
    version: u32,
    syno_token: Option<&str>,
) -> Result<Vec<Place>, CoreError> {
    let query = base_query(GEOCODING_API, version, offset, limit, sid);
    let body = get_body(transport, &query, syno_token).await?;
    let parsed: ListEnvelope = decode_envelope(&body)?;
    let total = parsed.list.len();
    let places: Vec<Place> = parsed
        .list
        .iter()
        .filter_map(|raw| {
            let g: RawGeocoding = decode_one(raw, "geocoding")?;
            Some(Place {
                id: g.id,
                name: g.name.unwrap_or_else(|| g.id.to_string()),
                country: g.country.unwrap_or_default(),
                first_level: g.first_level.unwrap_or_default(),
                second_level: g.second_level.unwrap_or_default(),
                item_count: g.item_count,
            })
        })
        .collect();
    log_skipped("geocoding", total, places.len());
    Ok(places)
}

/// `SYNO.Foto.Browse.GeneralTag`, `method=list`. Personal space only.
pub async fn list_tags(
    transport: &Transport,
    sid: &str,
    offset: u32,
    limit: u32,
    version: u32,
    syno_token: Option<&str>,
) -> Result<Vec<Tag>, CoreError> {
    let query = base_query(GENERAL_TAG_API, version, offset, limit, sid);
    let body = get_body(transport, &query, syno_token).await?;
    let parsed: ListEnvelope = decode_envelope(&body)?;
    let total = parsed.list.len();
    let tags: Vec<Tag> = parsed
        .list
        .iter()
        .filter_map(|raw| {
            let t: RawTag = decode_one(raw, "general tag")?;
            Some(Tag { id: t.id, name: t.name.unwrap_or_else(|| t.id.to_string()), item_count: t.item_count })
        })
        .collect();
    log_skipped("general tag", total, tags.len());
    Ok(tags)
}

/// `SYNO.Foto.Browse.Concept`, `method=list`. Personal space only.
///
/// The list itself is real and verified; no working `Browse.Item` filter
/// or dedicated item-list API was found for Concept on this NAS (see the
/// discovery-browse plan doc), so this lister exists to show Subjects in
/// the sidebar, but there is deliberately no matching `fetch_assets_for`
/// variant yet -- selecting a subject tile has nothing to route to.
pub async fn list_subjects(
    transport: &Transport,
    sid: &str,
    offset: u32,
    limit: u32,
    version: u32,
    syno_token: Option<&str>,
) -> Result<Vec<Subject>, CoreError> {
    let query = base_query(CONCEPT_API, version, offset, limit, sid);
    let body = get_body(transport, &query, syno_token).await?;
    let parsed: ListEnvelope = decode_envelope(&body)?;
    let total = parsed.list.len();
    let subjects: Vec<Subject> = parsed
        .list
        .iter()
        .filter_map(|raw| {
            let c: RawConcept = decode_one(raw, "concept")?;
            Some(Subject { id: c.id, name: c.name.unwrap_or_else(|| c.id.to_string()), item_count: c.item_count })
        })
        .collect();
    log_skipped("concept", total, subjects.len());
    Ok(subjects)
}

fn log_skipped(kind: &str, total: usize, kept: usize) {
    let skipped = total - kept;
    if skipped > 0 {
        tracing::warn!("{kind} list: skipped {} of {} elements (failed to decode)", skipped, total);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use models::Connection;

    fn conn(url: &str) -> Connection {
        Connection { host: url.to_string(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false }
    }

    #[tokio::test]
    async fn list_people_decodes_real_shape_and_sends_token_header() {
        let mut server = mockito::Server::new_async().await;
        let mock = server
            .mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("api".into(), PERSON_API.into()),
                mockito::Matcher::UrlEncoded("method".into(), "list".into()),
            ]))
            .match_header("X-SYNO-TOKEN", "TOK")
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[
                {"cover":39646,"id":12279,"item_count":23,"name":"","show":true},
                {"cover":39727,"id":12285,"item_count":8,"name":"Sahil","show":true}
            ]}}"#)
            .create_async()
            .await;
        let transport = Transport::new(&conn(&server.url())).unwrap();
        let people = list_people(&transport, "SID", 0, 50, 1, Some("TOK")).await.unwrap();
        assert_eq!(people.len(), 2);
        assert_eq!(people[0].id, 12279);
        assert!(people[0].name.is_empty(), "unnamed person must decode to empty name");
        assert_eq!(people[0].cover_unit_id, Some(39646));
        assert_eq!(people[1].name, "Sahil");
        mock.assert_async().await;
    }

    #[tokio::test]
    async fn list_people_omits_header_when_no_token() {
        let mut server = mockito::Server::new_async().await;
        let mock = server
            .mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[]}}"#)
            .create_async()
            .await;
        let transport = Transport::new(&conn(&server.url())).unwrap();
        let people = list_people(&transport, "SID", 0, 50, 1, None).await.unwrap();
        assert!(people.is_empty());
        mock.assert_async().await;
    }

    #[tokio::test]
    async fn list_people_skips_malformed_rows_without_failing_the_page() {
        let mut server = mockito::Server::new_async().await;
        server
            .mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[
                {"cover":1,"id":1,"item_count":1,"name":"","show":true},
                {"item_count":1}
            ]}}"#)
            .create_async()
            .await;
        let transport = Transport::new(&conn(&server.url())).unwrap();
        let people = list_people(&transport, "SID", 0, 50, 1, None).await.unwrap();
        assert_eq!(people.len(), 1, "the malformed row (missing id) must be skipped, not fail the whole page");
    }

    #[tokio::test]
    async fn list_places_decodes_real_geocoding_shape() {
        let mut server = mockito::Server::new_async().await;
        server
            .mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("api".into(), GEOCODING_API.into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[
                {"country":"Norway","country_id":1,"first_level":"Oslo","id":762,"item_count":10,"name":"Grunerlokka, Oslo","second_level":"Grunerlokka"}
            ]}}"#)
            .create_async()
            .await;
        let transport = Transport::new(&conn(&server.url())).unwrap();
        let places = list_places(&transport, "SID", 0, 50, 1, None).await.unwrap();
        assert_eq!(places.len(), 1);
        assert_eq!(places[0].name, "Grunerlokka, Oslo");
        assert_eq!(places[0].country, "Norway");
        assert_eq!(places[0].item_count, 10);
    }

    #[tokio::test]
    async fn list_tags_decodes_empty_list_cleanly() {
        let mut server = mockito::Server::new_async().await;
        server
            .mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("api".into(), GENERAL_TAG_API.into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[]}}"#)
            .create_async()
            .await;
        let transport = Transport::new(&conn(&server.url())).unwrap();
        let tags = list_tags(&transport, "SID", 0, 50, 1, None).await.unwrap();
        assert!(tags.is_empty(), "an empty tag list must decode cleanly, not error");
    }

    #[tokio::test]
    async fn list_tags_decodes_populated_shape() {
        let mut server = mockito::Server::new_async().await;
        server
            .mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("api".into(), GENERAL_TAG_API.into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[{"id":1,"name":"vacation","item_count":4}]}}"#)
            .create_async()
            .await;
        let transport = Transport::new(&conn(&server.url())).unwrap();
        let tags = list_tags(&transport, "SID", 0, 50, 1, None).await.unwrap();
        assert_eq!(tags.len(), 1);
        assert_eq!(tags[0].name, "vacation");
        assert_eq!(tags[0].item_count, 4);
    }

    #[tokio::test]
    async fn list_subjects_decodes_real_concept_shape() {
        let mut server = mockito::Server::new_async().await;
        server
            .mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("api".into(), CONCEPT_API.into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[
                {"display_threshold":1,"id":103,"item_count":2,"name":"Food","sort_index":10,"visibility":true}
            ]}}"#)
            .create_async()
            .await;
        let transport = Transport::new(&conn(&server.url())).unwrap();
        let subjects = list_subjects(&transport, "SID", 0, 50, 1, None).await.unwrap();
        assert_eq!(subjects.len(), 1);
        assert_eq!(subjects[0].name, "Food");
        assert_eq!(subjects[0].item_count, 2);
    }

    #[tokio::test]
    async fn list_people_maps_envelope_error() {
        let mut server = mockito::Server::new_async().await;
        server
            .mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":false,"error":{"code":400}}"#)
            .create_async()
            .await;
        let transport = Transport::new(&conn(&server.url())).unwrap();
        let err = list_people(&transport, "SID", 0, 50, 1, None).await.unwrap_err();
        assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
    }
}
