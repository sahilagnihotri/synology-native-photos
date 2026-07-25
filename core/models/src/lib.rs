//! Pure data types for synology-native-photos. No I/O.

uniffi::setup_scaffolding!();

pub const CRATE_MARKER: &str = "models";

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Space { Personal, Shared }

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum MediaKind { Photo, Video, Unknown }

/// Classify a file as `Video` or `Photo` purely from its filename extension.
///
/// Used by the recycle-bin listing (`RecycleItem`), where the only signal we
/// have for an item is its filename on disk (the DSM File Station listing
/// carries no Photos `type` marker). The video extensions (`.mov`, `.mp4`,
/// `.m4v`) match the ones the browse decoder treats as motion assets;
/// everything else defaults to `Photo` rather than `Unknown`, because a file
/// sitting in the Photos recycle folder is a photo unless it is obviously a
/// video, and a neutral `Unknown` would give the UI nothing useful to show.
/// The match is case-insensitive (`.MOV` and `.mov` are the same).
pub fn media_kind_from_filename(filename: &str) -> MediaKind {
    match filename.rsplit('.').next().map(|ext| ext.to_ascii_lowercase()).as_deref() {
        Some("mov") | Some("mp4") | Some("m4v") => MediaKind::Video,
        _ => MediaKind::Photo,
    }
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum ThumbnailSize { Sm, M, Xl }

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionState { Valid, Expired, Invalid }

/// A discovery-browse collection to fetch photos for: one of People,
/// Places, Tags, the user's Favorites, or one Album (normal or smart).
/// Personal space only (see `synology_api::browse::CollectionFilter`, which
/// this maps onto one-for-one); there is deliberately no `Subject` variant
/// because no working item filter was found for Concept/Subjects on the
/// real NAS.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum DiscoveryCollection {
    Person { id: i64 },
    Place { id: i64 },
    Tag { id: i64 },
    Favorites,
    Album { id: i64 },
}

/// Where a video/live asset can be played back from, as decided by
/// `photoscore::video_playback_source`.
///
/// Only `LocalFile` is produced today: the real NAS advertises
/// `SYNO.Foto.Streaming` (confirmed present in the SYNO.API.Info capability
/// probe, versions 1-2) but every plausible method name tried against it
/// (`stream`, `get`, `open`, `download`, `video`, `play`, `list`,
/// `stream_get`, `get_stream`) answered with Synology error 103 ("no such
/// method"), so no working streaming call has been found on this DSM build.
/// Per the feature brief's "correctness over cleverness" directive, the
/// guaranteed-working path (download the original, then play the local
/// file, exactly how `DetailQuickLookView` already previews photos) ships
/// now; `Url` is reserved for when a real Streaming method is found, so
/// callers must already handle both variants even though only one is
/// reachable yet.
#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum VideoPlaybackSource {
    /// A ready-to-play URL, including any auth the player needs (not yet
    /// produced by any code path; reserved for a future Streaming method).
    Url { url: String },
    /// An absolute path to a local file already downloaded in full, safe to
    /// hand straight to `AVPlayer`/`AVURLAsset`.
    LocalFile { path: String },
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct Connection {
    pub host: String,
    pub verify_tls: bool,
    pub pinned_cert_der: Option<Vec<u8>>,
    /// Last-resort dev escape hatch: when true AND no pinned cert is set,
    /// `build_client` disables all certificate validation
    /// (`danger_accept_invalid_certs`). THIS IS INSECURE: it accepts any
    /// certificate from any server, including a MITM. It exists only for
    /// local development against a NAS whose cert cannot yet be pinned.
    /// Must default to false and must only ever be flipped on by an
    /// explicit, clearly labeled opt-in toggle in the UI, never silently.
    /// The default path (no pin, this false) and the pinned path (a DER in
    /// `pinned_cert_der`) both keep full certificate validation regardless
    /// of this flag.
    pub allow_untrusted_tls: bool,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct Session {
    pub sid: String,
    pub syno_token: Option<String>,
    pub username: String,
    pub device_did: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct Asset {
    pub id: i64,
    /// The Synology unit id used for thumbnail/download requests. Distinct
    /// from `id` (the browse item id): the NAS thumbnail/download endpoints
    /// key on `additional.thumbnail.unit_id`, not on the item id, so this
    /// field is what fetch_thumbnail/download_original must send. Defaults
    /// to 0 when the server response did not carry a unit_id (see browse.rs);
    /// a 0 value means this asset cannot be thumbnailed/downloaded yet.
    pub unit_id: i64,
    pub cache_key: String,
    pub filename: String,
    pub media_kind: MediaKind,
    pub taken_at: Option<i64>,
    pub added_at: Option<i64>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub file_size: Option<u64>,
    pub space: Space,
    pub server_version: Option<i64>,
    // Per-asset metadata enrichment (from `Browse.Item`
    // `additional=["exif","description","rating","video_meta"]`, VERIFIED
    // shapes against the real NAS). All are kept flat and non-optional with a
    // neutral default so the surface matches the rest of `Asset` and round-
    // trips cleanly over UniFFI and persistence: a string field is "" when the
    // NAS omits it, `rating` is 0 (unrated). EXIF fields are populated mainly
    // for photos, the video_* fields only for videos; the other kind simply
    // leaves them empty. Formatting (duration to mm:ss, framerate rounding) is
    // deliberately left to the UI layer, so these hold the raw server values.
    /// 0..5 star rating (Synology's own scale); 0 means unrated.
    pub rating: i32,
    /// User-entered caption/description; "" when none.
    pub description: String,
    /// EXIF camera model, e.g. "Apple iPhone 12". "" when unknown.
    pub camera: String,
    /// EXIF aperture, e.g. "f/1.8" (raw server string). "" when unknown.
    pub aperture: String,
    /// EXIF exposure/shutter time, e.g. "1/120". "" when unknown.
    pub exposure_time: String,
    /// EXIF focal length, e.g. "26 mm". "" when unknown.
    pub focal_length: String,
    /// EXIF ISO, e.g. "100". "" when unknown.
    pub iso: String,
    /// EXIF lens model. "" when unknown.
    pub lens: String,
    /// Video duration, raw server value (e.g. milliseconds as a string).
    /// "" for non-videos or when the NAS omits it.
    pub duration: String,
    /// Video frame rate, raw server value (e.g. "29.97"). "" for non-videos.
    pub framerate: String,
    /// Video codec, e.g. "hevc". "" for non-videos.
    pub video_codec: String,
    /// Video container type, e.g. "mov". "" for non-videos.
    pub container_type: String,
}

/// A neutral, empty `Asset`. Not produced by any real decode path (those set
/// every field explicitly); it exists so test fixtures and future incremental
/// constructors can spread `..Default::default()` over the metadata fields
/// they do not care about instead of restating every field. Purely Rust-side:
/// UniFFI binding generation is unaffected by this impl.
impl Default for Asset {
    fn default() -> Self {
        Asset {
            id: 0,
            unit_id: 0,
            cache_key: String::new(),
            filename: String::new(),
            media_kind: MediaKind::Unknown,
            taken_at: None,
            added_at: None,
            width: None,
            height: None,
            file_size: None,
            space: Space::Personal,
            server_version: None,
            rating: 0,
            description: String::new(),
            camera: String::new(),
            aperture: String::new(),
            exposure_time: String::new(),
            focal_length: String::new(),
            iso: String::new(),
            lens: String::new(),
            duration: String::new(),
            framerate: String::new(),
            video_codec: String::new(),
            container_type: String::new(),
        }
    }
}

/// One file recovered from the DSM home recycle bin under
/// `/home/#recycle/Photos/...`, as surfaced by the "real delete" flow.
///
/// The everyday delete now removes an item from the Photos library outright
/// (`SYNO.Foto.Browse.Item` `method=delete`), which lands the physical
/// original in the home recycle bin at the mirrored path. That recycle bin is
/// browsed with DSM File Station, which knows nothing about the Photos index,
/// so a recovered file is described here by its filesystem facts rather than
/// by a Photos item id: `recycle_path` is the absolute path inside
/// `#recycle` (the handle used to restore or permanently delete it),
/// `filename` is the leaf name, `deleted_at` is the File Station `mtime`
/// (which is when the file was moved into the recycle bin), `file_size` is
/// the byte size, and `media_kind` is derived from the filename extension via
/// `media_kind_from_filename` (photo unless it is obviously a video).
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct RecycleItem {
    pub recycle_path: String,
    pub filename: String,
    pub deleted_at: i64,
    pub file_size: u64,
    pub media_kind: MediaKind,
}

/// One row from `SYNO.Foto.Browse.Album`: either a user-created normal album
/// or a rule-based smart (condition) album; the two share this one list
/// surface on the real NAS (see `synology_api::browse::list_albums`'s doc
/// comment for the confirmed request/response shape).
///
/// `cover_unit_id` is the id the thumbnail endpoint keys on for the album's
/// cover photo, mirrored from `additional.thumbnail.unit_id` the same way
/// `Asset.unit_id` is (VERIFIED elsewhere in this crate that thumbnail
/// endpoints key on unit_id, not an item id); `None` when the album has no
/// cover yet (e.g. an empty album). `is_smart`/`is_shared` are best-effort:
/// the real NAS account probed for this feature has zero albums of either
/// kind, so the exact JSON marker for "this is a condition album" / "this
/// album is shared" could not be captured from a live non-empty response.
/// Both default to `false` when the marker is absent rather than failing
/// decode, so an unrecognized/renamed marker degrades to "normal, unshared"
/// rather than breaking the list.
#[derive(uniffi::Record, Clone, Debug)]
pub struct Album {
    pub id: i64,
    pub name: String,
    pub item_count: u32,
    pub cover_cache_key: Option<String>,
    pub cover_unit_id: Option<i64>,
    pub is_shared: bool,
    pub is_smart: bool,
    pub space: Space,
}

/// One row from `SYNO.Foto.Browse.Person`: a face cluster DSM has detected.
/// `name` is the empty string for a person DSM has not been given a name
/// for yet (the app shows this as a disabled "Add Name" placeholder rather
/// than naming people itself, which is a later, gated mutation). `cover`
/// is the unit_id DSM reports for the cluster's representative thumbnail;
/// it goes through the same thumbnail fetch path as `Asset.unit_id`, but
/// has no `cache_key` of its own (Person does not return one), so callers
/// pass an empty cache_key when fetching it. `show` mirrors DSM's own
/// "hide this person" toggle; a hidden person is still modeled here (never
/// silently dropped) so the caller can decide whether to filter it.
#[derive(uniffi::Record, Clone, Debug)]
pub struct Person {
    pub id: i64,
    pub name: String,
    pub item_count: u32,
    pub cover_unit_id: Option<i64>,
    pub show: bool,
}

/// One row from `SYNO.Foto.Browse.Geocoding`: a place cluster DSM has
/// grouped photos into by location. `name` is the ready-to-display label
/// DSM already composes (e.g. "Grunerlokka, Oslo"); `country`/
/// `first_level`/`second_level` are kept for a caller that wants to build
/// its own hierarchy or grouping instead of the flat `name`. Geocoding
/// rows carry no cover thumbnail on this API (verified against the real
/// NAS), so there is no `cover_unit_id` field here.
#[derive(uniffi::Record, Clone, Debug)]
pub struct Place {
    pub id: i64,
    pub name: String,
    pub country: String,
    pub first_level: String,
    pub second_level: String,
    pub item_count: u32,
}

/// One row from `SYNO.Foto.Browse.Concept` ("Subjects" in the sidebar).
/// VERIFIED against the real NAS: the list API itself works and returns
/// real categories (Food, Nature, Animals, Transportation, ...), but no
/// working `Browse.Item` filter param or dedicated item-list API was found
/// for it (see the discovery-browse plan doc for every candidate tried).
/// This model exists so the list can still be shown; `fetch_assets_for`
/// intentionally has no `Subject` variant yet, so selecting a subject tile
/// has nothing to route to until DSM's filter surface for Concept is
/// found.
#[derive(uniffi::Record, Clone, Debug)]
pub struct Subject {
    pub id: i64,
    pub name: String,
    pub item_count: u32,
}

/// One row from `SYNO.Foto.Browse.GeneralTag`. VERIFIED shape against the
/// real NAS (the list itself was empty -- no tags exist yet on this
/// account -- but the envelope decodes cleanly either way). The
/// `general_tag_id` Browse.Item filter param was confirmed accepted (a
/// made-up id returns a clean empty list rather than being silently
/// ignored) though not yet exercised against a real non-empty tag.
#[derive(uniffi::Record, Clone, Debug)]
pub struct Tag {
    pub id: i64,
    pub name: String,
    pub item_count: u32,
}

/// One entry in a `SearchFacets` catalog: an id/name pair as returned by
/// `SYNO.Foto.Search.Filter`. Shared shape for `cameras`, `apertures`, and
/// `geocodings` (the geocoding tree is flattened -- see
/// `synology_api::search_filter`'s doc comment for how nested regions are
/// walked into one flat list of leaves-and-branches).
///
/// VERIFIED against the real NAS: these three facets are listed correctly
/// by `Search.Filter`, but NEITHER `SYNO.Foto.Search.Search list_item` NOR
/// `SYNO.Foto.Browse.Item` accepts a working filter param for any of them
/// on this NAS/DSM build (`camera_id`, `aperture_id`, `geocoding_id`, and
/// several JSON-blob shapes -- `condition={...}`, `filter={...}` -- were all
/// probed with a real id alongside a bogus-id control; every one returned
/// the exact same unfiltered result set for both, the signature of a
/// silently-ignored param rather than a real filter). So `Facet` values
/// here are shown for browsing/labeling only; the UI cannot yet filter
/// search results by camera/aperture/place. `Place`/`geocoding_id` remains
/// filterable through `Browse.Item`'s discovery-browse `CollectionFilter`
/// (a different, already-working code path), just not through
/// `Search.Search`.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct Facet {
    pub id: i64,
    pub name: String,
}

/// The facet catalog from `SYNO.Foto.Search.Filter`, `method=list`.
/// `cameras`/`apertures`/`geocodings` are listed for display only (see
/// `Facet`'s doc comment: no working filter param exists for them yet).
/// `media_types` mirrors the `item_type` facet DSM lists (this account only
/// ever reports `photo`); it is likewise display-only, since neither
/// `item_type` nor `media_type` filtered `Search.Search list_item` in the
/// probe (bogus and real values returned identical unfiltered lists).
///
/// There is deliberately no field for `exposure_time_group`, `iso`, `lens`,
/// `flash`, `focal_length_group`, `folder_filter`, `general_tag`, `person`,
/// `rating`, or the `time` buckets: none of these had a confirmed, working
/// filter param on `Search.Search list_item` either, and the brief calls
/// for dropping (not faking) a facet with no confirmable filter. Time
/// filtering IS supported, but through the free `start_time`/`end_time`
/// unix-second range on `SearchFilters` below, not through DSM's
/// preset month buckets, so it needs no catalog entry here.
#[derive(uniffi::Record, Clone, Debug)]
pub struct SearchFacets {
    pub cameras: Vec<Facet>,
    pub apertures: Vec<Facet>,
    pub geocodings: Vec<Facet>,
    pub media_types: Vec<Facet>,
}

/// The one confirmed-working filter set for `SYNO.Foto.Search.Search
/// list_item`: an inclusive `start_time`/`end_time` unix-second range,
/// verified against the real NAS with an exact-second boundary test (a
/// `start_time` one second after a known item's `time` excluded it; an
/// `end_time` one second before it excluded it while keeping earlier items).
/// Both ends are optional so a caller can filter with only a floor, only a
/// ceiling, or both. `None` in both fields means "no date filter" -- the
/// same as omitting the params entirely.
#[derive(uniffi::Record, Clone, Debug, Default, PartialEq)]
pub struct SearchFilters {
    pub start_time: Option<i64>,
    pub end_time: Option<i64>,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct CrawlProgress {
    pub space: Space,
    pub done: u64,
    pub total: u64,
    pub complete: bool,
}

/// One calendar-day bucket in a space's library date histogram, as produced
/// by `persistence::Store::date_histogram` / `PhotosCore::date_histogram`.
///
/// `day_start` is the unix second at the start of the day the bucket covers,
/// using the same UTC-day bucketing the histogram groups by (the day boundary
/// falls at multiples of 86400 seconds). `count` is the number of non-trashed
/// assets in that day. Buckets are returned newest day first, and their
/// concatenation reproduces `fetch_assets`' global ordering exactly, so the
/// grid can map a (section, row) coordinate to a flat absolute index purely
/// from these counts without loading any asset.
///
/// Assets with no `taken_at` are collected into a single trailing bucket with
/// `day_start = 0` ("Unknown Date"), which sorts last to match `fetch_assets`
/// putting NULL-`taken_at` rows at the end. A real photo timestamped at the
/// unix epoch (1970-01-01) would share `day_start = 0` with that bucket; such
/// timestamps do not occur in practice, so the UI treats `day_start == 0` as
/// the Unknown Date bucket by convention.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct DayCount {
    pub day_start: i64,
    pub count: u32,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct ApiCapability {
    pub name: String,
    pub path: String,
    pub min_version: u32,
    pub max_version: u32,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct ThumbnailData {
    pub cached_path: String,
    pub bytes: Vec<u8>,
}

/// The server's leaf TLS certificate, captured for trust-on-first-use
/// approval. `der` is the raw certificate bytes (suitable for storing as
/// `Connection.pinned_cert_der` once the user approves it); `sha256_hex` is
/// the fingerprint to show the user; `subject` is a human-readable subject
/// name (e.g. the certificate's CN) for display alongside the fingerprint.
#[derive(uniffi::Record, Clone, Debug)]
pub struct CertInfo {
    pub der: Vec<u8>,
    pub sha256_hex: String,
    pub subject: String,
}

#[derive(uniffi::Error, Debug, thiserror::Error)]
pub enum CoreError {
    #[error("authentication failed: {message}")]
    Auth { message: String },

    #[error("two-factor code required or incorrect")]
    OtpRequired,

    #[error("network error: {message}")]
    Network { message: String },

    #[error("decode error: {message}")]
    Decode { message: String },

    #[error("unexpected server response: {message}")]
    UnexpectedResponse { message: String },

    #[error("write refused: read-only mode")]
    WriteRefused,

    #[error("storage error: {message}")]
    Storage { message: String },

    #[error("capability unavailable: {api}")]
    CapabilityUnavailable { api: String },
}

#[cfg(test)]
mod tests {
    use crate::*;

    #[test]
    fn crate_marker_is_present() {
        assert_eq!(CRATE_MARKER, "models");
    }

    #[test]
    fn asset_holds_all_contract_fields() {
        let a = Asset {
            id: 42,
            unit_id: 4242,
            cache_key: "ck-1".to_string(),
            filename: "IMG_0001.HEIC".to_string(),
            media_kind: MediaKind::Photo,
            taken_at: Some(1_700_000_000),
            added_at: None,
            width: Some(4032),
            height: Some(3024),
            file_size: Some(2_500_000),
            space: Space::Personal,
            server_version: Some(7),
            rating: 4,
            description: "sunset".to_string(),
            camera: "Apple iPhone 12".to_string(),
            aperture: "f/1.8".to_string(),
            exposure_time: "1/120".to_string(),
            focal_length: "26 mm".to_string(),
            iso: "100".to_string(),
            lens: "iPhone 12 back camera".to_string(),
            duration: String::new(),
            framerate: String::new(),
            video_codec: String::new(),
            container_type: String::new(),
        };
        assert_eq!(a.id, 42);
        assert_eq!(a.unit_id, 4242);
        assert_eq!(a.space, Space::Personal);
        assert_eq!(a.media_kind, MediaKind::Photo);
        assert_eq!(a.width, Some(4032));
        assert_eq!(a.rating, 4);
        assert_eq!(a.description, "sunset");
        assert_eq!(a.camera, "Apple iPhone 12");
        assert_eq!(a.iso, "100");
    }

    #[test]
    fn asset_default_is_neutral_and_empty() {
        let a = Asset::default();
        assert_eq!(a.rating, 0);
        assert_eq!(a.description, "");
        assert_eq!(a.camera, "");
        assert_eq!(a.duration, "");
        assert_eq!(a.media_kind, MediaKind::Unknown);
    }

    #[test]
    fn connection_shape() {
        let c = Connection {
            host: "https://192.168.1.10:5001".to_string(),
            verify_tls: true,
            pinned_cert_der: None,
            allow_untrusted_tls: false,
        };
        assert!(c.verify_tls);
        assert!(c.pinned_cert_der.is_none());
        assert!(!c.allow_untrusted_tls, "allow_untrusted_tls must default-construct false in every call site");
    }

    #[test]
    fn session_optionals() {
        let s = Session {
            sid: "SID123".to_string(),
            syno_token: Some("tok".to_string()),
            username: "photobot".to_string(),
            device_did: None,
        };
        assert_eq!(s.username, "photobot");
        assert_eq!(s.syno_token.as_deref(), Some("tok"));
    }

    #[test]
    fn crawl_progress_barrier_flag() {
        let p = CrawlProgress { space: Space::Shared, done: 10, total: 100, complete: false };
        assert!(!p.complete);
        assert_eq!(p.space, Space::Shared);
    }

    #[test]
    fn day_count_holds_day_start_and_count() {
        let d = DayCount { day_start: 1_479_513_600, count: 7 };
        assert_eq!(d.day_start, 1_479_513_600);
        assert_eq!(d.count, 7);
        assert_eq!(d, DayCount { day_start: 1_479_513_600, count: 7 });
        // The Unknown Date bucket convention: day_start 0.
        let unknown = DayCount { day_start: 0, count: 3 };
        assert_ne!(unknown, d);
    }

    #[test]
    fn core_error_display_messages() {
        let e = CoreError::Auth { message: "bad pw".to_string() };
        assert_eq!(e.to_string(), "authentication failed: bad pw");
        assert_eq!(CoreError::OtpRequired.to_string(), "two-factor code required or incorrect");
        assert_eq!(CoreError::WriteRefused.to_string(), "write refused: read-only mode");
        let cap = CoreError::CapabilityUnavailable { api: "SYNO.Foto.Browse.Item".to_string() };
        assert_eq!(cap.to_string(), "capability unavailable: SYNO.Foto.Browse.Item");
    }

    #[test]
    fn thumbnail_size_variants_distinct() {
        assert_ne!(ThumbnailSize::Sm, ThumbnailSize::Xl);
        assert_eq!(ThumbnailSize::M, ThumbnailSize::M);
    }

    #[test]
    fn person_holds_unnamed_and_named_shapes() {
        let unnamed = Person { id: 12279, name: String::new(), item_count: 23, cover_unit_id: Some(39646), show: true };
        assert!(unnamed.name.is_empty(), "an unnamed person must round-trip as an empty name, not a placeholder string");
        let named = Person { id: 1, name: "Sahil".to_string(), item_count: 5, cover_unit_id: None, show: false };
        assert_eq!(named.name, "Sahil");
        assert!(!named.show);
    }

    #[test]
    fn place_holds_all_geocoding_fields() {
        let p = Place {
            id: 762,
            name: "Grunerlokka, Oslo".to_string(),
            country: "Norway".to_string(),
            first_level: "Oslo".to_string(),
            second_level: "Grunerlokka".to_string(),
            item_count: 10,
        };
        assert_eq!(p.item_count, 10);
        assert_eq!(p.country, "Norway");
    }

    #[test]
    fn subject_and_tag_hold_id_name_count() {
        let s = Subject { id: 103, name: "Food".to_string(), item_count: 2 };
        assert_eq!(s.name, "Food");
        let t = Tag { id: 1, name: "vacation".to_string(), item_count: 4 };
        assert_eq!(t.item_count, 4);
    }

    #[test]
    fn discovery_collection_variants_carry_their_ids() {
        let person = DiscoveryCollection::Person { id: 12279 };
        let place = DiscoveryCollection::Place { id: 756 };
        let tag = DiscoveryCollection::Tag { id: 5 };
        let favorites = DiscoveryCollection::Favorites;
        let album = DiscoveryCollection::Album { id: 42 };
        assert_eq!(person, DiscoveryCollection::Person { id: 12279 });
        assert_ne!(person, place);
        assert_ne!(tag, favorites);
        assert_eq!(album, DiscoveryCollection::Album { id: 42 });
        assert_ne!(album, favorites);
    }

    #[test]
    fn facet_holds_id_and_name() {
        let f = Facet { id: 23, name: "iPhone 6s".to_string() };
        assert_eq!(f.id, 23);
        assert_eq!(f.name, "iPhone 6s");
        assert_eq!(f, Facet { id: 23, name: "iPhone 6s".to_string() });
    }

    #[test]
    fn search_facets_holds_display_only_catalogs() {
        let facets = SearchFacets {
            cameras: vec![Facet { id: 23, name: "iPhone 6s".to_string() }],
            apertures: vec![Facet { id: 1, name: "F1.8".to_string() }],
            geocodings: vec![Facet { id: 12, name: "Oslo".to_string() }],
            media_types: vec![Facet { id: 0, name: "photo".to_string() }],
        };
        assert_eq!(facets.cameras.len(), 1);
        assert_eq!(facets.apertures[0].name, "F1.8");
        assert_eq!(facets.geocodings[0].id, 12);
        assert_eq!(facets.media_types[0].name, "photo");
    }

    #[test]
    fn search_filters_default_is_no_date_filter() {
        let f = SearchFilters::default();
        assert!(f.start_time.is_none());
        assert!(f.end_time.is_none());
    }

    #[test]
    fn search_filters_holds_start_and_end() {
        let f = SearchFilters { start_time: Some(1_400_000_000), end_time: Some(1_500_000_000) };
        assert_eq!(f.start_time, Some(1_400_000_000));
        assert_eq!(f.end_time, Some(1_500_000_000));
        assert_ne!(f, SearchFilters::default());
    }

    #[test]
    fn video_playback_source_variants_are_distinct() {
        let local = VideoPlaybackSource::LocalFile { path: "/tmp/syno-orig-abc".to_string() };
        let url = VideoPlaybackSource::Url { url: "https://nas.example.com/stream".to_string() };
        assert_ne!(local, url);
        assert_eq!(local, VideoPlaybackSource::LocalFile { path: "/tmp/syno-orig-abc".to_string() });
    }

    #[test]
    fn media_kind_from_filename_classifies_videos_case_insensitively() {
        assert_eq!(media_kind_from_filename("IMG_0924.MOV"), MediaKind::Video);
        assert_eq!(media_kind_from_filename("clip.mov"), MediaKind::Video);
        assert_eq!(media_kind_from_filename("clip.mp4"), MediaKind::Video);
        assert_eq!(media_kind_from_filename("clip.M4V"), MediaKind::Video);
    }

    #[test]
    fn media_kind_from_filename_defaults_everything_else_to_photo() {
        assert_eq!(media_kind_from_filename("IMG_0924.JPG"), MediaKind::Photo);
        assert_eq!(media_kind_from_filename("photo.heic"), MediaKind::Photo);
        assert_eq!(media_kind_from_filename("scan.png"), MediaKind::Photo);
        // No extension at all still degrades to Photo rather than Unknown.
        assert_eq!(media_kind_from_filename("noextension"), MediaKind::Photo);
        assert_eq!(media_kind_from_filename(""), MediaKind::Photo);
    }

    #[test]
    fn recycle_item_holds_all_fields() {
        let item = RecycleItem {
            recycle_path: "/home/#recycle/Photos/iPhone/2016/09/IMG_0924.JPG".to_string(),
            filename: "IMG_0924.JPG".to_string(),
            deleted_at: 1_600_000_000,
            file_size: 2_500_000,
            media_kind: media_kind_from_filename("IMG_0924.JPG"),
        };
        assert_eq!(item.filename, "IMG_0924.JPG");
        assert_eq!(item.deleted_at, 1_600_000_000);
        assert_eq!(item.file_size, 2_500_000);
        assert_eq!(item.media_kind, MediaKind::Photo);
        assert_eq!(item, item.clone());
    }

    #[test]
    fn album_holds_smart_and_shared_flags() {
        let normal = Album {
            id: 5,
            name: "Trip".to_string(),
            item_count: 42,
            cover_cache_key: Some("COVER5".to_string()),
            cover_unit_id: Some(55805),
            is_shared: false,
            is_smart: false,
            space: Space::Personal,
        };
        assert!(!normal.is_smart);
        assert!(!normal.is_shared);
        let smart = Album {
            id: 9,
            name: "Sunsets".to_string(),
            item_count: 12,
            cover_cache_key: None,
            cover_unit_id: None,
            is_shared: true,
            is_smart: true,
            space: Space::Personal,
        };
        assert!(smart.is_smart);
        assert!(smart.is_shared);
    }
}
