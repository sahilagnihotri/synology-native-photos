//! The UniFFI boundary crate exposing PhotosCore to Swift.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

use models::{
    Album, ApiCapability, Asset, CertInfo, Connection, CoreError, CrawlProgress, DiscoveryCollection, Person, Place,
    SearchFacets, SearchFilters, Session, SessionState, Space, Subject, Tag, ThumbnailData, ThumbnailSize,
    VideoPlaybackSource,
};
use persistence::Store;
use sync_engine::crawl::{Crawler, ProgressSink};
use sync_engine::delta::DeltaReconciler;
use sync_engine::{AssetPage, PageSource};
use synology_api::browse::CollectionFilter;
use synology_api::namespace::{browse_album_api, browse_item_api, normal_album_api};
use synology_api::Transport;

uniffi::setup_scaffolding!("photoscore");

/// The exact, fixed name of the app-owned album that backs the everyday
/// "delete". An item "deleted" in the app is moved into this album (fully
/// reversible, never the raw NAS delete verb) and hidden from the library
/// grid via the local `in_trash` flag. The name is stable and human-readable
/// so a user browsing Synology Photos directly on another device sees an
/// obviously-named recovery album rather than a cryptic app-internal one.
const RECENTLY_DELETED_ALBUM: &str = "Recently Deleted";

/// `app_state` key under which the id of the app-created trash album is
/// persisted per space. The trash album is owned by this stored id, never by a
/// name match, so a user's own album that happens to be named
/// "Recently Deleted" can never be adopted as trash.
const TRASH_ALBUM_ID_KEY: &str = "trash_album_id";

/// Trivial cross-boundary smoke function. Returns the core crate version.
/// Proves Swift can call into Rust over UniFFI before the full PhotosCore lands.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Implemented on the Swift side; called from Rust during crawl_space.
#[uniffi::export(callback_interface)]
pub trait FfiCrawlObserver: Send + Sync {
    fn on_progress(&self, progress: CrawlProgress);
}

/// Adapts synology-api's `list_items` onto the sync-engine `PageSource`
/// trait for one fixed transport/session/API-version triple. sync-engine
/// only ever sees this trait, never the HTTP client directly.
struct ApiPageSource {
    transport: Transport,
    sid: String,
    version: u32,
    syno_token: Option<String>,
}

#[async_trait::async_trait]
impl PageSource for ApiPageSource {
    async fn list_items(&self, space: Space, offset: u32, limit: u32) -> Result<AssetPage, CoreError> {
        let assets = synology_api::list_items(
            &self.transport,
            &self.sid,
            space,
            offset,
            limit,
            self.version,
            self.syno_token.as_deref(),
        )
        .await?;
        // The Browse.Item list does not return a grand total on every DSM build; when
        // absent we treat a short page as the end. Report the running count as total so
        // the barrier still flips on the final short page (offset >= total holds).
        let total = if (assets.len() as u32) < limit {
            (offset as u64) + assets.len() as u64
        } else {
            (offset as u64) + limit as u64 + 1
        };
        Ok(AssetPage { assets, total })
    }
}

/// Adapts the UniFFI callback interface onto sync-engine's internal
/// `ProgressSink`, so sync-engine stays free of UniFFI concerns.
struct ObserverSink {
    observer: Box<dyn FfiCrawlObserver>,
}
impl ProgressSink for ObserverSink {
    fn emit(&self, progress: CrawlProgress) {
        self.observer.on_progress(progress);
    }
}

/// Post-login connection state held inside the core.
struct Live {
    transport: Transport,
    session: Session,
    connection: Connection,
    capabilities: Vec<ApiCapability>,
}

/// The single UniFFI-exported facade. Swift holds one instance per app run.
///
/// `Store` wraps a `rusqlite::Connection`, whose internal statement cache uses
/// a `RefCell` and so is not `Sync`. UniFFI objects are shared across threads
/// as `Arc<Self>`, so `store` is held behind a `Mutex` (like `live`) rather
/// than bare, to satisfy `Send + Sync` and to make the cross-thread access
/// pattern explicit rather than accidental.
///
/// Because `Store` is not `Sync`, `&Store` is not `Send` either, so a
/// `Crawler`/`DeltaReconciler` borrowing it can never be held across an
/// `.await` inside a future the tokio `async_runtime` binding requires to be
/// `Send` (uniffi's exported async methods must return a `Send` future).
/// `crawl_space`/`reconcile_delta` route around this by taking the `Store`
/// *out* of the mutex by value and moving it onto a dedicated blocking
/// thread (`spawn_blocking`), where the whole crawl - including its
/// internal network awaits - runs synchronously via `Handle::block_on`; the
/// owned `Store` is moved back into the mutex once the blocking task
/// returns, even if the crawl itself panicked partway through (the panic is
/// caught on the blocking thread and turned into an ordinary error, see
/// `run_with_store`), so a single bad crawl can never leave the core
/// permanently unusable. The mutex guard itself is only ever held for the
/// instant of the swap, never across any `.await`.
#[derive(uniffi::Object)]
pub struct PhotosCore {
    /// `Option` so `run_with_store` can `take()` the owned `Store` out for
    /// the duration of a blocking-thread crawl and put it back afterward,
    /// without ever holding the mutex guard itself across an `.await`.
    /// Empty (`None`) only for the brief window while a crawl/reconcile is
    /// actually running on its blocking thread; every other method observes
    /// `Some`.
    store: Mutex<Option<Store>>,
    cache_dir: String,
    live: Mutex<Option<Live>>,
    /// Cache of the resolved "Recently Deleted" album id per space, so the
    /// delete/restore/reconcile paths do not re-list albums on every call.
    /// Populated by `ensure_trash_album` on first resolve; a plain `HashMap`
    /// behind a `Mutex` since it is tiny (one entry per space) and only ever
    /// touched under a short-lived lock, never across an `.await`. Refreshed
    /// (not left stale) whenever `ensure_trash_album` finds the stored id no
    /// longer exists on the NAS and creates a fresh album.
    trash_album_ids: Mutex<HashMap<Space, i64>>,
    /// Serializes every trash-MUTATING operation (delete_to_trash,
    /// restore_from_trash, permanently_delete, reconcile_trash, and
    /// ensure_trash_album) so they never interleave. This is a `tokio::Mutex`,
    /// not the std `Mutex` that guards `store`: it is deliberately held across
    /// `.await` points for the whole operation, which closes a TOCTOU where a
    /// concurrent restore could clear an item's `in_trash` flag in between
    /// `permanently_delete`'s guard check and its network delete. Acquired
    /// exactly once per public call; the internal `*_inner` helpers never
    /// re-acquire it, so a public method that delegates to another
    /// (delete_to_trash -> the trash-album resolve) cannot self-deadlock.
    trash_lock: tokio::sync::Mutex<()>,
}

#[uniffi::export(async_runtime = "tokio")]
impl PhotosCore {
    /// Construct with a local DB directory. Opens/creates SQLite + runs migrations.
    #[uniffi::constructor]
    pub fn new(db_dir: String, cache_dir: String) -> Result<Arc<Self>, CoreError> {
        let db_path = std::path::Path::new(&db_dir).join("photos.sqlite");
        let store = Store::open_at(&db_path)?;
        Ok(Arc::new(PhotosCore {
            store: Mutex::new(Some(store)),
            cache_dir,
            live: Mutex::new(None),
            trash_album_ids: Mutex::new(HashMap::new()),
            trash_lock: tokio::sync::Mutex::new(()),
        }))
    }

    /// Log in against `connection` with the given credentials.
    ///
    /// `otp_code` and `device_token` are forwarded to `synology_api::login`
    /// untouched:
    /// - `otp_code = None` omits the param entirely, so an account with 2FA
    ///   enabled answers with `CoreError::OtpRequired` (see
    ///   `synology_api::auth`), which the Swift UI is expected to catch,
    ///   prompt for a code, and retry with `otp_code = Some(code)`.
    /// - `device_token` should be the value previously returned on
    ///   `Session.device_did` from an earlier login on this host+account
    ///   (the caller/UI is responsible for persisting it, e.g. Keychain).
    ///   Passing it lets a trusted device skip OTP; DSM rejecting a stale
    ///   token falls back to the same `CoreError::OtpRequired` as no token
    ///   at all (fail-closed, see `synology_api::auth` doc comment).
    ///
    /// On success, replaces any previously held `Live` state with a fresh
    /// transport/session pair (capability probe deferred to first use, so
    /// login itself stays a single round trip). The returned `Session`
    /// carries any device token DSM minted/confirmed in `device_did`; the
    /// caller is expected to persist it for a future `device_token` login.
    pub async fn login(
        &self,
        connection: Connection,
        username: String,
        password: String,
        otp_code: Option<String>,
        device_token: Option<String>,
    ) -> Result<Session, CoreError> {
        let transport = Transport::new(&connection)?;
        let session = synology_api::login(&transport, &username, &password, otp_code.as_deref(), device_token.as_deref()).await?;
        let mut guard = self.live.lock().expect("live mutex poisoned");
        *guard = Some(Live {
            transport,
            session: session.clone(),
            connection,
            capabilities: Vec::new(),
        });
        Ok(session)
    }

    /// Fetches the TLS certificate presented by `host` for trust-on-first-use
    /// approval, without ever trusting it for a real request (see
    /// `synology_api::fetch_server_cert_der` for exactly what is and is not
    /// relaxed during this one-shot probe).
    ///
    /// This is a standalone, session-free call: it can be made before
    /// `login` (indeed, that is the intended flow) to let the UI show the
    /// user the server's fingerprint + subject and get their approval before
    /// ever sending credentials anywhere. Approving means storing the
    /// returned `CertInfo.der` (Keychain or app config) and passing it as
    /// `Connection.pinned_cert_der` on the `Connection` used for `login`.
    pub async fn fetch_certificate(&self, host: String) -> Result<CertInfo, CoreError> {
        synology_api::fetch_server_cert_der(&host).await
    }

    /// Rebuild `Live` state from a previously stored `Session` (e.g. loaded
    /// from the Keychain) without re-running the login handshake.
    ///
    /// Validates the session with a cheap authed capability probe
    /// (`SYNO.API.Info`): a probe failure that maps to `CoreError::Auth` or
    /// `CoreError::OtpRequired` means the stored session is no longer
    /// accepted by DSM, so this reports `SessionState::Expired` rather than
    /// an error the caller has to handle as failure - the UI can react by
    /// sending the user back through `login`. Any other probe error (e.g.
    /// network failure) is fail-closed and propagated as-is.
    pub async fn restore_session(
        &self,
        connection: Connection,
        session: Session,
    ) -> Result<SessionState, CoreError> {
        let transport = Transport::new(&connection)?;
        match synology_api::probe_capabilities(&transport).await {
            Ok(caps) => {
                let mut guard = self.live.lock().expect("live mutex poisoned");
                *guard = Some(Live { transport, session, connection, capabilities: caps });
                Ok(SessionState::Valid)
            }
            Err(CoreError::Auth { .. }) | Err(CoreError::OtpRequired) => Ok(SessionState::Expired),
            Err(other) => Err(other),
        }
    }

    /// Sign out: best-effort server-side logout, then unconditionally drop
    /// `Live` and clear the per-account thumbnail cache dir contents.
    ///
    /// Idempotent by construction: if no session is held, `taken` is `None`,
    /// the server logout call is skipped, and clearing an already-empty (or
    /// absent) cache dir is a no-op, so calling `sign_out` with nothing to
    /// sign out of always succeeds.
    pub async fn sign_out(&self) -> Result<(), CoreError> {
        let taken = {
            let mut guard = self.live.lock().expect("live mutex poisoned");
            guard.take()
        };
        if let Some(live) = taken {
            let _ = synology_api::logout(&live.transport, &live.session.sid).await;
        }
        // Clear the per-account thumbnail cache dir contents (read-only teardown).
        let thumbs = std::path::Path::new(&self.cache_dir).join("thumbs");
        if thumbs.exists() {
            let _ = std::fs::remove_dir_all(&thumbs);
        }
        Ok(())
    }

    /// Probe `SYNO.API.Info` over the live session and cache the discovered
    /// capability set into `Live.capabilities` for later version pinning
    /// (Tasks 36/37 read it via `pin_version`).
    ///
    /// Fails closed with `CoreError::Auth` if no session is held rather than
    /// panicking: a caller that never logged in gets an error to handle, not
    /// a crash.
    ///
    /// A fresh `Transport` is rebuilt from the stored `Connection` inside the
    /// lock, then the lock is dropped before the `.await` so the std `Mutex`
    /// guard is never held across an await point.
    pub async fn probe_capabilities(&self) -> Result<Vec<ApiCapability>, CoreError> {
        let transport = {
            let guard = self.live.lock().expect("live mutex poisoned");
            match guard.as_ref() {
                Some(live) => Transport::new(&live.connection)?,
                None => return Err(CoreError::Auth { message: "not logged in".into() }),
            }
        };
        let caps = synology_api::probe_capabilities(&transport).await?;
        if let Some(live) = self.live.lock().expect("live mutex poisoned").as_mut() {
            live.capabilities = caps.clone();
        }
        Ok(caps)
    }

    /// Drives a resumable full crawl of `space` to completion (or until
    /// interrupted by an error), reporting `CrawlProgress` to `observer`
    /// after every page via `ObserverSink`.
    ///
    /// Requires a live session: fails closed with `CoreError::Auth` if
    /// `login`/`restore_session` has not populated `Live`. `page_source_for`
    /// takes the `live` std `Mutex` guard only long enough to clone the
    /// transport/sid/version it needs and drops it before returning, well
    /// before any `.await` here runs.
    ///
    /// The crawl itself runs via `run_with_store` (see its doc comment):
    /// the `store` mutex is only ever locked for the instant needed to move
    /// the `Store` out and back in, never across an `.await`.
    pub async fn crawl_space(
        &self,
        space: Space,
        observer: Box<dyn FfiCrawlObserver>,
    ) -> Result<CrawlProgress, CoreError> {
        let source = self.page_source_for(space)?;
        let sink = ObserverSink { observer };
        self.run_with_store(move |store| {
            Box::pin(async move {
                let crawler = Crawler::new(store, &source, 200);
                crawler.crawl_space(space, &sink).await
            })
        })
        .await
    }

    /// Runs delta reconciliation (new/changed/deleted) for `space` against
    /// the live session. Same auth and lock discipline as `crawl_space`.
    pub async fn reconcile_delta(&self, space: Space) -> Result<CrawlProgress, CoreError> {
        let source = self.page_source_for(space)?;
        self.run_with_store(move |store| {
            Box::pin(async move {
                let reconciler = DeltaReconciler::new(store, &source, 200);
                reconciler.reconcile(space).await
            })
        })
        .await
    }

    /// Reads back the persisted crawl progress for `space` with no network
    /// access at all. A plain sync `fn` (per the brief's signature); it
    /// takes the `store` std `Mutex` only for the duration of the read, so
    /// it can never be the source of contention with a concurrent crawl -
    /// it simply waits its turn like any other `Mutex` user.
    pub fn crawl_progress(&self, space: Space) -> Result<CrawlProgress, CoreError> {
        let guard = self.store.lock().expect("store mutex poisoned");
        let store = guard.as_ref().ok_or_else(store_busy_err)?;
        store.crawl_progress(space)
    }

    /// Local-only asset count for `space`; used by tests and diagnostics.
    pub fn asset_count(&self, space: Space) -> Result<u64, CoreError> {
        let guard = self.store.lock().expect("store mutex poisoned");
        let store = guard.as_ref().ok_or_else(store_busy_err)?;
        store.asset_count(space)
    }

    /// Windowed local read of assets in `space`, newest-first, for the grid's
    /// scrolling. No network access at all: this is a plain sync `fn` that
    /// only ever locks `store` for the duration of the read, so it can never
    /// block on (or be blocked by) a concurrent crawl for longer than that
    /// crawl needs to swap the `Store` back in.
    pub fn fetch_assets(&self, space: Space, offset: u32, limit: u32) -> Result<Vec<Asset>, CoreError> {
        let guard = self.store.lock().expect("store mutex poisoned");
        let store = guard.as_ref().ok_or_else(store_busy_err)?;
        store.fetch_assets(space, offset, limit)
    }

    /// Local read of every album in `space`, ordered by name. No network
    /// access; same lock discipline as `fetch_assets`/`asset_count`.
    ///
    /// Not currently wired to anything crawling albums into the local
    /// index (nothing populates the `albums` table yet), so this always
    /// returns whatever was upserted by a prior test/tool run, typically
    /// empty. The user-visible Albums sidebar reads the live NAS-backed
    /// `fetch_albums` below instead, matching the discovery-browse
    /// collections (no local index for those either).
    pub fn fetch_local_albums(&self, space: Space) -> Result<Vec<Album>, CoreError> {
        let guard = self.store.lock().expect("store mutex poisoned");
        let store = guard.as_ref().ok_or_else(store_busy_err)?;
        store.fetch_albums(space)
    }

    /// Lists albums (`SYNO.Foto.Browse.Album`), a live network call every
    /// time: same discipline as `fetch_people`/`fetch_tags`/etc, there is no
    /// local index for the live NAS album list in this pass. Personal space
    /// only, matching every other discovery-browse lister in this facade.
    /// Requires a live session; fails closed with `CoreError::Auth`
    /// otherwise.
    pub async fn fetch_albums(&self, offset: u32, limit: u32) -> Result<Vec<Album>, CoreError> {
        let (transport, sid, version, syno_token) = self.discovery_call_context("SYNO.Foto.Browse.Album")?;
        synology_api::list_albums(&transport, &sid, Space::Personal, offset, limit, version, syno_token.as_deref())
            .await
    }

    /// Lists People (`SYNO.Foto.Browse.Person`), a live network call every
    /// time: unlike `fetch_assets`/`fetch_albums`, discovery-browse
    /// collections have no local index in this pass, so this always hits
    /// the NAS. Requires a live session; fails closed with `CoreError::Auth`
    /// otherwise.
    pub async fn fetch_people(&self, offset: u32, limit: u32) -> Result<Vec<Person>, CoreError> {
        let (transport, sid, version, syno_token) = self.discovery_call_context("SYNO.Foto.Browse.Person")?;
        synology_api::list_people(&transport, &sid, offset, limit, version, syno_token.as_deref()).await
    }

    /// Lists Places (`SYNO.Foto.Browse.Geocoding`). Same live-call and auth
    /// discipline as `fetch_people`.
    pub async fn fetch_places(&self, offset: u32, limit: u32) -> Result<Vec<Place>, CoreError> {
        let (transport, sid, version, syno_token) = self.discovery_call_context("SYNO.Foto.Browse.Geocoding")?;
        synology_api::list_places(&transport, &sid, offset, limit, version, syno_token.as_deref()).await
    }

    /// Lists Subjects (`SYNO.Foto.Browse.Concept`). Same live-call and auth
    /// discipline as `fetch_people`. Listing works; there is deliberately no
    /// `fetch_assets_for` variant for a subject yet (see
    /// `DiscoveryCollection`'s doc comment), so a subject tile has nothing
    /// to route to on this NAS until a working item filter is found.
    pub async fn fetch_subjects(&self, offset: u32, limit: u32) -> Result<Vec<Subject>, CoreError> {
        let (transport, sid, version, syno_token) = self.discovery_call_context("SYNO.Foto.Browse.Concept")?;
        synology_api::list_subjects(&transport, &sid, offset, limit, version, syno_token.as_deref()).await
    }

    /// Lists Tags (`SYNO.Foto.Browse.GeneralTag`). Same live-call and auth
    /// discipline as `fetch_people`.
    pub async fn fetch_tags(&self, offset: u32, limit: u32) -> Result<Vec<Tag>, CoreError> {
        let (transport, sid, version, syno_token) = self.discovery_call_context("SYNO.Foto.Browse.GeneralTag")?;
        synology_api::list_tags(&transport, &sid, offset, limit, version, syno_token.as_deref()).await
    }

    /// Fetches the photos belonging to one discovery-browse `collection`
    /// (a person, place, tag, an album, or the user's favorites), windowed
    /// the same way `fetch_assets` windows the library grid. Unlike
    /// `fetch_assets`, this always hits the NAS directly (no local index
    /// for discovery collections yet), but keeps the same unit_id/token
    /// invariants every other browse call in this crate relies on.
    ///
    /// Requires a live session; fails closed with `CoreError::Auth`
    /// otherwise. Personal space only, matching
    /// `synology_api::browse::CollectionFilter`'s own scope.
    pub async fn fetch_assets_for(
        &self,
        collection: DiscoveryCollection,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<Asset>, CoreError> {
        let (transport, sid, version, syno_token) = self.discovery_call_context("SYNO.Foto.Browse.Item")?;
        let filter = match collection {
            DiscoveryCollection::Person { id } => CollectionFilter::Person(id),
            DiscoveryCollection::Place { id } => CollectionFilter::Place(id),
            DiscoveryCollection::Tag { id } => CollectionFilter::Tag(id),
            DiscoveryCollection::Favorites => CollectionFilter::Favorites,
            DiscoveryCollection::Album { id } => CollectionFilter::Album(id),
        };
        synology_api::list_items_filtered(&transport, &sid, filter, offset, limit, version, syno_token.as_deref())
            .await
    }

    /// Keyword search (`SYNO.Foto.Search.Search`, method `list_item`),
    /// windowed the same way `fetch_assets_for` windows a discovery
    /// collection: always a live NAS call, no local index. Personal space
    /// only, matching the confirmed real-NAS scope (see the search plan
    /// doc for the probe transcript). An empty or no-match keyword
    /// resolves to an empty `Vec`, not an error; the caller (the app's
    /// empty-state UI) treats that as "no results", never as a failure.
    ///
    /// Requires a live session; fails closed with `CoreError::Auth`
    /// otherwise.
    pub async fn search_assets(&self, keyword: String, offset: u32, limit: u32) -> Result<Vec<Asset>, CoreError> {
        let (transport, sid, version, syno_token) = self.discovery_call_context("SYNO.Foto.Search.Search")?;
        synology_api::search(&transport, &sid, &keyword, offset, limit, version, syno_token.as_deref()).await
    }

    /// Same as `search_assets`, but additionally narrows results to
    /// `filters.start_time`/`filters.end_time` (unix seconds), the one
    /// confirmed-working facet filter on `Search.Search list_item` -- see
    /// `models::SearchFilters`'s doc comment for the probe that ruled every
    /// camera/aperture/geocoding/media-type candidate out. A default
    /// `SearchFilters` (both fields `None`) behaves exactly like
    /// `search_assets`.
    ///
    /// Requires a live session; fails closed with `CoreError::Auth`
    /// otherwise.
    pub async fn search_assets_filtered(
        &self,
        keyword: String,
        filters: SearchFilters,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<Asset>, CoreError> {
        let (transport, sid, version, syno_token) = self.discovery_call_context("SYNO.Foto.Search.Search")?;
        synology_api::search_filtered(&transport, &sid, &keyword, &filters, offset, limit, version, syno_token.as_deref()).await
    }

    /// Fetches the search facet catalog (`SYNO.Foto.Search.Filter`,
    /// `method=list`): camera, aperture, and geocoding facets for display,
    /// plus the media-type list. See `models::SearchFacets`'s doc comment
    /// for why these are shown but not (yet) filterable -- only the date
    /// range on `search_assets_filtered` is a real working filter on this
    /// NAS.
    ///
    /// A live network call every time, same discipline as
    /// `fetch_people`/`fetch_places`/etc: no local index for the facet
    /// catalog. Requires a live session; fails closed with `CoreError::Auth`
    /// otherwise.
    pub async fn fetch_search_facets(&self) -> Result<SearchFacets, CoreError> {
        let (transport, sid, _version, syno_token) = self.discovery_call_context("SYNO.Foto.Search.Filter")?;
        synology_api::search_facets(&transport, &sid, syno_token.as_deref()).await
    }

    /// Fetches a thumbnail for `unit_id` at `size`, served from a
    /// composite-key on-disk cache whenever possible.
    ///
    /// `unit_id` MUST be `Asset.unit_id` (from `additional.thumbnail.unit_id`
    /// on the browse response), NOT `Asset.id`. The Synology thumbnail
    /// endpoint keys on unit_id; sending the browse item id returns an html
    /// error page instead of image bytes, which is the root cause of a
    /// previous blank-thumbnail bug. Callers (the Swift ThumbnailCache) pass
    /// `asset.unitId`.
    ///
    /// The cache path is `{cache_dir}/thumbs/{hex_digest}.jpg`, where
    /// `hex_digest` is a hash of `(space, unit_id, size, cache_key)`. Hashing
    /// the composite key rather than interpolating any of its parts (in
    /// particular the NAS-supplied `cache_key`) directly into the filename
    /// means the filename is always a fixed-length hex string: no path
    /// separator, no `..`, no length blowup can ever reach the filesystem,
    /// even if `cache_key` were ever malformed or unexpectedly large. A
    /// changed `cache_key` still hashes to a different digest, so this keeps
    /// the same invalidation property as before: whenever the server-side
    /// asset changes and the NAS mints a new cache_key, the new call produces
    /// a different path and can never be served a stale file.
    ///
    /// On a cache hit, this returns entirely from disk with no network
    /// access. On a miss, `live` is locked only long enough to clone the
    /// transport/sid/version triple it needs; the guard is dropped before the
    /// `fetch_thumbnail` `.await`, matching the discipline used by
    /// `page_source_for`/`crawl_space` elsewhere in this file. The fetched
    /// bytes are written atomically (temp file in the same directory, then
    /// renamed into place) so a concurrent reader/writer or a symlink planted
    /// at the target path can never observe a partial write or be written
    /// through.
    ///
    /// Fails closed with `CoreError::Auth` if no session is held.
    pub async fn thumbnail(
        &self,
        space: Space,
        unit_id: i64,
        cache_key: String,
        size: ThumbnailSize,
    ) -> Result<ThumbnailData, CoreError> {
        let dir = std::path::Path::new(&self.cache_dir).join("thumbs");
        let path = dir.join(format!("{}.jpg", cache_digest(&[space_tag(space), &unit_id.to_string(), size_tag(size), &cache_key])));
        if path.exists() {
            let bytes = std::fs::read(&path).map_err(|e| CoreError::Storage { message: e.to_string() })?;
            return Ok(ThumbnailData { cached_path: path.to_string_lossy().into(), bytes });
        }

        let (transport, sid, version, syno_token) = {
            let guard = self.live.lock().expect("live mutex poisoned");
            let live = guard.as_ref().ok_or(CoreError::Auth { message: "not logged in".into() })?;
            let api = match space {
                Space::Personal => "SYNO.Foto.Thumbnail",
                Space::Shared => "SYNO.FotoTeam.Thumbnail",
            };
            let version = synology_api::pin_version(&live.capabilities, api, 2).unwrap_or(2);
            (Transport::new(&live.connection)?, live.session.sid.clone(), version, live.session.syno_token.clone())
        };

        let bytes = synology_api::fetch_thumbnail(
            &transport,
            &sid,
            space,
            unit_id,
            &cache_key,
            size,
            version,
            syno_token.as_deref(),
        )
        .await?;
        write_cache_file_atomically(&dir, &path, &bytes)?;
        Ok(ThumbnailData { cached_path: path.to_string_lossy().into(), bytes })
    }

    /// Downloads the original full-resolution bytes for `unit_id` to a
    /// temp file and returns its absolute path. Read-only: never writes
    /// anything back to the NAS.
    ///
    /// `unit_id` MUST be `Asset.unit_id`, not `Asset.id`, for the same
    /// reason as `thumbnail` above: the download endpoint keys on unit_id.
    ///
    /// Same lock discipline as `thumbnail`: `live` is locked only long enough
    /// to clone the transport/sid/version triple, then dropped before the
    /// network `.await`. The destination filename is a hash of
    /// `(unit_id, cache_key)` for the same path-safety reason as `thumbnail`
    /// (the NAS-supplied `cache_key` never appears literally in a path), and
    /// the bytes are written atomically (temp file, then renamed into place).
    ///
    /// Fails closed with `CoreError::Auth` if no session is held.
    pub async fn download_original(
        &self,
        space: Space,
        unit_id: i64,
        cache_key: String,
    ) -> Result<String, CoreError> {
        let (transport, sid, version, syno_token) = {
            let guard = self.live.lock().expect("live mutex poisoned");
            let live = guard.as_ref().ok_or(CoreError::Auth { message: "not logged in".into() })?;
            let api = match space {
                Space::Personal => "SYNO.Foto.Download",
                Space::Shared => "SYNO.FotoTeam.Download",
            };
            let version = synology_api::pin_version(&live.capabilities, api, 2).unwrap_or(2);
            (Transport::new(&live.connection)?, live.session.sid.clone(), version, live.session.syno_token.clone())
        };

        let bytes = synology_api::download_original(
            &transport,
            &sid,
            space,
            unit_id,
            &cache_key,
            version,
            syno_token.as_deref(),
        )
        .await?;
        let dir = std::env::temp_dir();
        let tmp = dir.join(format!("syno-orig-{}", cache_digest(&[&unit_id.to_string(), &cache_key])));
        write_cache_file_atomically(&dir, &tmp, &bytes)?;
        Ok(tmp.to_string_lossy().into())
    }

    /// Resolves how the detail viewer should play back `asset` (a video,
    /// including the motion `.MOV` component of a Live Photo, which now
    /// classifies as `MediaKind::Video` via its `live_type` -- see
    /// `models::VideoPlaybackSource`'s doc comment).
    ///
    /// READ-ONLY PROBE FINDING (verified against the real NAS): SYNO.API.Info
    /// genuinely advertises `SYNO.Foto.Streaming` (and `SYNO.FotoTeam.Streaming`),
    /// versions 1-2, so the API exists on this DSM build. However every
    /// plausible method name tried against it (`stream`, `get`, `open`,
    /// `download`, `video`, `play`, `list`, `stream_get`, `get_stream`) answered
    /// with Synology error 103 ("no such method"), so no working streaming
    /// call was found. Per the feature brief's "correctness over cleverness"
    /// directive, this always returns `VideoPlaybackSource::LocalFile` today,
    /// downloading the asset's original bytes exactly the way
    /// `download_original` already does for still photos (same cache
    /// directory, same atomic-write discipline, same unit_id/cache_key
    /// contract) and handing back the local path for `AVPlayer` to open
    /// directly. `VideoPlaybackSource::Url` is reserved for whenever a real
    /// Streaming method is found; no code path produces it yet.
    ///
    /// Same lock discipline and auth-fail-closed behavior as
    /// `download_original`, which this delegates to internally.
    pub async fn video_playback_source(&self, space: Space, asset: Asset) -> Result<VideoPlaybackSource, CoreError> {
        let path = self.download_original(space, asset.unit_id, asset.cache_key).await?;
        Ok(VideoPlaybackSource::LocalFile { path })
    }

    // --- Phase 2a: hybrid safe delete -----------------------------------

    /// Resolves the app-owned `Recently Deleted` album for `space`, creating
    /// it on the NAS if it does not exist yet.
    ///
    /// OWNERSHIP BY ID, NEVER BY NAME (safety): the app persists the id of the
    /// album it created (`app_state`), and this method adopts an existing
    /// album ONLY when its id equals that stored id and it is still present on
    /// the NAS. A user's own album that merely happens to be named
    /// "Recently Deleted" is never adopted, so its contents can never be
    /// silently flagged as trash (and thus permanent-delete eligible). If no
    /// id is stored, or the stored id no longer exists on the NAS, a fresh
    /// album is created, its returned id persisted, and the in-memory cache
    /// refreshed to it (never left serving the dead id).
    ///
    /// Serialized with every other trash mutation via `trash_lock`. Requires a
    /// live session; fails closed with `CoreError::Auth`. Never touches the
    /// raw delete verb: this only manages an album.
    pub async fn ensure_trash_album(&self, space: Space) -> Result<Album, CoreError> {
        let _lock = self.trash_lock.lock().await;
        self.ensure_trash_album_inner(space).await
    }

    /// Everyday delete: moves `asset_ids` into the `Recently Deleted` album on
    /// the NAS, then (ONLY on server success) flags them `in_trash` locally in
    /// one transaction so they leave the library grid and appear in the trash
    /// view.
    ///
    /// SAFETY: this NEVER calls the raw Foto delete verb; the move is fully
    /// reversible via `restore_from_trash`. Server confirms first: on any
    /// error from `add_items`, no local flag changes (fail closed). An empty
    /// `asset_ids` is a no-op. Serialized with every other trash mutation via
    /// `trash_lock`.
    ///
    /// ATOMICITY: the server move and the local flag write are each
    /// individually transactional but NOT jointly atomic. The only failure
    /// window is "server move succeeded, local flag write failed" (e.g. the
    /// store was momentarily busy): the item is in the NAS trash album but not
    /// yet hidden locally. That is the safe direction (nothing is lost or
    /// permanently deleted) and self-heals on the next `reconcile_trash`,
    /// which re-derives the local flags from the album's real membership.
    ///
    /// Requires a live session; fails closed with `CoreError::Auth`.
    pub async fn delete_to_trash(&self, space: Space, asset_ids: Vec<i64>) -> Result<(), CoreError> {
        if asset_ids.is_empty() {
            return Ok(());
        }
        let _lock = self.trash_lock.lock().await;
        let album_id = self.trash_album_id_inner(space).await?;
        let (transport, sid, version, syno_token) = self.write_call_context(normal_album_api(space), 1)?;
        synology_api::add_items(&transport, &sid, space, album_id, &asset_ids, version, syno_token.as_deref()).await?;
        // Server confirmed the move; now, and only now, mirror it locally.
        let guard = self.store.lock().expect("store mutex poisoned");
        let store = guard.as_ref().ok_or_else(store_busy_err)?;
        store.set_trash_flag(space, &asset_ids, true, Some(now_secs()))
    }

    /// Restore: removes `asset_ids` from the `Recently Deleted` album on the
    /// NAS, then (ONLY on server success) clears their local `in_trash` flag
    /// so they return to the library grid. Reverses `delete_to_trash` exactly.
    /// Fail closed on any error; empty `asset_ids` is a no-op. Serialized with
    /// every other trash mutation via `trash_lock`.
    ///
    /// ATOMICITY: same shape as `delete_to_trash`. The server remove and the
    /// local flag clear are individually transactional but not jointly atomic;
    /// the only failure window ("removed on the NAS, still flagged locally")
    /// is the safe direction (the item stays visible in the trash view, never
    /// lost) and self-heals on the next `reconcile_trash`.
    ///
    /// Requires a live session; fails closed with `CoreError::Auth`.
    pub async fn restore_from_trash(&self, space: Space, asset_ids: Vec<i64>) -> Result<(), CoreError> {
        if asset_ids.is_empty() {
            return Ok(());
        }
        let _lock = self.trash_lock.lock().await;
        let album_id = self.trash_album_id_inner(space).await?;
        let (transport, sid, version, syno_token) = self.write_call_context(normal_album_api(space), 1)?;
        synology_api::remove_items(&transport, &sid, space, album_id, &asset_ids, version, syno_token.as_deref())
            .await?;
        let guard = self.store.lock().expect("store mutex poisoned");
        let store = guard.as_ref().ok_or_else(store_busy_err)?;
        store.set_trash_flag(space, &asset_ids, false, None)
    }

    /// Windowed local read of trashed assets in `space`, most-recently-trashed
    /// first. No network access at all; same lock discipline as
    /// `fetch_assets`.
    pub fn fetch_trash(&self, space: Space, offset: u32, limit: u32) -> Result<Vec<Asset>, CoreError> {
        let guard = self.store.lock().expect("store mutex poisoned");
        let store = guard.as_ref().ok_or_else(store_busy_err)?;
        store.fetch_trash(space, offset, limit)
    }

    /// Local count of trashed assets in `space`. No network access.
    pub fn trash_count(&self, space: Space) -> Result<u32, CoreError> {
        let guard = self.store.lock().expect("store mutex poisoned");
        let store = guard.as_ref().ok_or_else(store_busy_err)?;
        Ok(store.trash_count(space)? as u32)
    }

    /// Gated PERMANENT delete: the only path to the raw Foto delete verb.
    ///
    /// SAFETY (the point of the hybrid design): this FIRST asserts, against
    /// the local mirror, that every id in `asset_ids` is currently
    /// `in_trash`. If any is not, it returns `CoreError::WriteRefused`
    /// WITHOUT making any network call at all (see the `all_in_trash` guard
    /// below). That guarantees the destructive endpoint can never be reached
    /// for an asset that skipped the reversible trash step, closing off any UI
    /// bug that tries to permanently delete a live photo directly. Only after
    /// the guard passes does it call `permanent_delete`; on server success it
    /// removes the local rows entirely (the NAS drops the item from the trash
    /// album automatically when the item is deleted, so no separate
    /// `remove_items` is needed). Empty `asset_ids` is a no-op.
    ///
    /// SERIALIZED: holds `trash_lock` across the whole guard-then-delete
    /// sequence, so a concurrent `restore_from_trash` cannot clear an item's
    /// `in_trash` flag in the window between the guard check and the network
    /// delete. Without that, the guard could pass on a still-trashed asset, a
    /// restore could run, and the raw delete would then land on an asset the
    /// user just restored. The lock makes the check-and-delete atomic against
    /// every other trash mutation.
    ///
    /// ATOMICITY of the server-then-local steps: the network delete and the
    /// local row removal are individually transactional but not jointly
    /// atomic; the only failure window ("deleted on the NAS, local row still
    /// present") is the safe direction (the item shows in the trash view until
    /// the next reconcile drops it) and self-heals on `reconcile_trash`.
    ///
    /// Requires a live session; fails closed with `CoreError::Auth`.
    pub async fn permanently_delete(&self, space: Space, asset_ids: Vec<i64>) -> Result<(), CoreError> {
        if asset_ids.is_empty() {
            return Ok(());
        }
        let _lock = self.trash_lock.lock().await;
        // Dedup so the guard's distinct-count check is not tripped by a
        // repeated id in the caller's list.
        let mut ids = asset_ids;
        ids.sort_unstable();
        ids.dedup();
        // GUARD: no network call unless every id is already in the trash.
        {
            let guard = self.store.lock().expect("store mutex poisoned");
            let store = guard.as_ref().ok_or_else(store_busy_err)?;
            if !store.all_in_trash(space, &ids)? {
                return Err(CoreError::WriteRefused);
            }
        }
        let (transport, sid, version, syno_token) = self.write_call_context(browse_item_api(space), 7)?;
        synology_api::permanent_delete(&transport, &sid, space, &ids, version, syno_token.as_deref()).await?;
        // Confirmed gone from the NAS; drop the local rows entirely.
        let guard = self.store.lock().expect("store mutex poisoned");
        let store = guard.as_ref().ok_or_else(store_busy_err)?;
        store.delete_assets(space, &ids)?;
        Ok(())
    }

    /// Reconciles the local `in_trash` flags against the real membership of
    /// the `Recently Deleted` album on the NAS. Flags `in_trash = 1` for every
    /// current member not already flagged, and (guardedly) clears `in_trash`
    /// for any locally-trashed id that is no longer a member, which is how a
    /// restore performed from another Synology client (e.g. the mobile app) is
    /// picked up. Safe to call after a crawl. Serialized with every other
    /// trash mutation via `trash_lock`. Requires a live session.
    ///
    /// SAFETY against a spurious empty/short listing: clearing flags is the
    /// only direction that can un-hide (and thus re-expose to permanent
    /// delete) trashed items, so it is gated. This method resolves the trash
    /// album by its stored id ONLY (never adopts by name, never creates here),
    /// and treats the album's `item_count` as ground truth: it clears
    /// non-member flags ONLY when the fully paged member set is authoritative,
    /// i.e. the enumerated count equals `item_count`. If no trash album is
    /// known, or the enumerated count does not match `item_count` (a truncated
    /// or spurious-empty listing), it SKIPS the clear entirely and logs,
    /// rather than mass-clearing every local trash flag. Flagging members as
    /// trashed (the hide direction) is always safe and is applied regardless.
    /// A member-fetch error propagates before any local mutation (fail
    /// closed).
    pub async fn reconcile_trash(&self, space: Space) -> Result<(), CoreError> {
        let _lock = self.trash_lock.lock().await;

        // Resolve the trash album by its stored id ONLY. Never adopt by name,
        // never create here: if we cannot positively identify the app's own
        // trash album, we must not clear anything.
        let albums = self.list_all_albums(space).await?;
        let stored = self.stored_trash_album_id(space)?;
        let album = match stored.and_then(|id| albums.iter().find(|a| a.id == id).cloned()) {
            Some(a) => a,
            None => {
                tracing::warn!(
                    "reconcile_trash: no identifiable trash album for {space:?} (none stored, or the stored id is absent from the album list); skipping to avoid mass-unhiding trash"
                );
                return Ok(());
            }
        };
        let album_id = album.id;
        let expected = album.item_count;

        let (transport, sid, version, syno_token) = self.write_call_context(browse_item_api(space), 1)?;
        let mut member_ids: Vec<i64> = Vec::new();
        let mut offset = 0u32;
        let limit = 1000u32;
        loop {
            let page = synology_api::list_items_filtered(
                &transport,
                &sid,
                CollectionFilter::Album(album_id),
                offset,
                limit,
                version,
                syno_token.as_deref(),
            )
            .await?;
            let n = page.len() as u32;
            member_ids.extend(page.iter().map(|a| a.id));
            if n < limit {
                break;
            }
            offset += limit;
        }

        // The clear step is authoritative only when the fully paged member set
        // matches the album's reported size. A short/empty listing (network
        // hiccup) would otherwise un-hide the entire trash.
        let fully_enumerated = member_ids.len() as u32 == expected;

        let member_set: HashSet<i64> = member_ids.iter().copied().collect();
        let guard = self.store.lock().expect("store mutex poisoned");
        let store = guard.as_ref().ok_or_else(store_busy_err)?;
        let currently: Vec<i64> = store.fetch_trash(space, 0, u32::MAX)?.iter().map(|a| a.id).collect();
        let currently_set: HashSet<i64> = currently.iter().copied().collect();
        // Members not yet flagged locally get flagged (only these, so an
        // already-trashed item keeps its original trashed_at rather than
        // having it reset to now on every reconcile). Always safe (hide only).
        let to_add: Vec<i64> = member_ids.iter().copied().filter(|id| !currently_set.contains(id)).collect();
        store.set_trash_flag(space, &to_add, true, Some(now_secs()))?;
        if fully_enumerated {
            // Locally-trashed ids that are no longer album members get restored.
            let to_remove: Vec<i64> = currently.iter().copied().filter(|id| !member_set.contains(id)).collect();
            store.set_trash_flag(space, &to_remove, false, None)?;
        } else {
            tracing::warn!(
                "reconcile_trash: enumerated {} member(s) but album {album_id} reports item_count {expected}; skipping the clear step to avoid mass-unhiding trash",
                member_ids.len()
            );
        }
        Ok(())
    }
}

/// Maps a `ThumbnailSize` to its stable path-tag string. No injection
/// surface: values come from a closed enum, never from NAS-supplied data.
fn size_tag(size: ThumbnailSize) -> &'static str {
    match size {
        ThumbnailSize::Sm => "sm",
        ThumbnailSize::M => "m",
        ThumbnailSize::Xl => "xl",
    }
}

/// Maps a `Space` to its stable path-tag string. No injection surface: values
/// come from a closed enum, never from NAS-supplied data.
fn space_tag(space: Space) -> &'static str {
    match space {
        Space::Personal => "personal",
        Space::Shared => "shared",
    }
}

/// Hashes a composite cache key (any number of string parts, e.g. `space`,
/// `asset_id`, `size`, `cache_key`) into a fixed-length hex digest suitable
/// for use as a filename.
///
/// This is the sole defense against path traversal in the disk cache: none
/// of the input parts (in particular the NAS-supplied `cache_key`, which is
/// otherwise unsanitized) ever appear literally in the resulting path. A `/`,
/// a `..` segment, or an absurdly long value in any part changes the digest
/// but can never itself reach the filesystem, because the digest is always
/// exactly 16 lowercase hex characters. Two composite keys that differ in any
/// part hash to different digests (barring a hash collision), which
/// preserves the existing cache invalidation property: a changed `cache_key`
/// still produces a different cache path and is always treated as a miss.
///
/// Uses `std::collections::hash_map::DefaultHasher`, which is fine here: this
/// is a cache filename, not a cryptographic or adversarial-collision
/// context, and the parts are delimited (hashed one at a time with a
/// separator) so distinct part boundaries can't be confused with each other.
fn cache_digest(parts: &[&str]) -> String {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut hasher = DefaultHasher::new();
    for part in parts {
        part.hash(&mut hasher);
        0u8.hash(&mut hasher); // separator so ("ab","c") != ("a","bc")
    }
    format!("{:016x}", hasher.finish())
}

/// Writes `bytes` to `final_path` atomically: creates `dir` if missing,
/// writes to a freshly named temp file inside `dir`, then renames it into
/// place. `rename` within the same directory is atomic on macOS (and POSIX
/// generally), so any concurrent reader of `final_path` either sees the
/// complete old file or the complete new file, never a partial write.
///
/// This also removes the symlink/TOCTOU risk of writing straight to
/// `final_path`: the temp file is always a brand-new, uniquely named path (no
/// pre-existing file or symlink for `create_new` to follow), and `rename`
/// replaces whatever is at `final_path` wholesale rather than opening and
/// writing through it, so a symlink planted at `final_path` is atomically
/// swapped out rather than dereferenced and written into.
fn write_cache_file_atomically(dir: &std::path::Path, final_path: &std::path::Path, bytes: &[u8]) -> Result<(), CoreError> {
    std::fs::create_dir_all(dir).map_err(|e| CoreError::Storage { message: e.to_string() })?;
    let unique = format!(".tmp-{}-{}", std::process::id(), cache_digest(&[&std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos().to_string()]));
    let tmp_path = dir.join(unique);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&tmp_path)
        .map_err(|e| CoreError::Storage { message: e.to_string() })?;
    use std::io::Write;
    let write_result = file.write_all(bytes).and_then(|_| file.sync_all());
    if let Err(e) = write_result {
        let _ = std::fs::remove_file(&tmp_path);
        return Err(CoreError::Storage { message: e.to_string() });
    }
    drop(file);
    std::fs::rename(&tmp_path, final_path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp_path);
        CoreError::Storage { message: e.to_string() }
    })
}

/// The `store` mutex briefly holds `None` only while a crawl/reconcile has
/// taken the `Store` out to run on its blocking thread. Any other caller
/// landing in that window gets a clear, fail-closed error rather than a
/// panic on `Option::unwrap`.
fn store_busy_err() -> CoreError {
    CoreError::Storage { message: "store busy: a crawl or reconcile is in progress".into() }
}

/// Current wall-clock time in whole seconds since the Unix epoch, used to
/// stamp `trashed_at` when an item is moved to trash. Mirrors persistence's
/// own `now_secs` (that one is crate-private); a clock before the epoch
/// degrades to 0 rather than panicking.
fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

impl PhotosCore {
    /// Builds an `ApiPageSource` bound to the currently live session for
    /// `space`, pinning the browse-item API version from the cached
    /// capability set (falling back to `1` if capabilities were never
    /// probed). Locks `live` only long enough to clone what is needed; the
    /// guard is dropped before returning, well before any caller `.await`s
    /// the resulting source's `list_items`.
    fn page_source_for(&self, _space: Space) -> Result<ApiPageSource, CoreError> {
        let guard = self.live.lock().expect("live mutex poisoned");
        let live = guard.as_ref().ok_or(CoreError::Auth { message: "not logged in".into() })?;
        let version = synology_api::pin_version(&live.capabilities, "SYNO.Foto.Browse.Item", 1)
            .or_else(|_| synology_api::pin_version(&live.capabilities, "SYNO.FotoTeam.Browse.Item", 1))
            .unwrap_or(1);
        Ok(ApiPageSource {
            transport: Transport::new(&live.connection)?,
            sid: live.session.sid.clone(),
            version,
            syno_token: live.session.syno_token.clone(),
        })
    }

    /// Builds the `(transport, sid, version, syno_token)` tuple every
    /// discovery-browse facade method (`fetch_people`/`fetch_places`/
    /// `fetch_subjects`/`fetch_tags`/`fetch_assets_for`) needs, pinning
    /// `api`'s version from the cached capability set the same way
    /// `page_source_for` does for `SYNO.Foto.Browse.Item`. Falls back to `1`
    /// if `api` was never probed (matching `page_source_for`'s own
    /// fallback) rather than failing closed on a capability-probe gap alone;
    /// a genuinely absent/removed API still surfaces as whatever error the
    /// request itself returns.
    ///
    /// Locks `live` only long enough to clone what is needed; the guard is
    /// dropped before returning, well before any caller `.await`s the
    /// resulting transport's network call, same discipline as
    /// `page_source_for`/`thumbnail`/`download_original`.
    fn discovery_call_context(&self, api: &str) -> Result<(Transport, String, u32, Option<String>), CoreError> {
        let guard = self.live.lock().expect("live mutex poisoned");
        let live = guard.as_ref().ok_or(CoreError::Auth { message: "not logged in".into() })?;
        let version = synology_api::pin_version(&live.capabilities, api, 1).unwrap_or(1);
        Ok((
            Transport::new(&live.connection)?,
            live.session.sid.clone(),
            version,
            live.session.syno_token.clone(),
        ))
    }

    /// Same as `discovery_call_context`, but lets the caller pin a specific
    /// `desired` version (the album write calls want v1, the item delete
    /// wants v7). Clamps into the advertised window when `api` is known,
    /// falling back to `desired` when the capability probe never saw `api`
    /// (matching `discovery_call_context`'s own fallback). Locks `live` only
    /// long enough to clone what is needed; the guard is dropped before the
    /// caller `.await`s the write, same discipline as every other context
    /// builder here.
    fn write_call_context(
        &self,
        api: &str,
        desired: u32,
    ) -> Result<(Transport, String, u32, Option<String>), CoreError> {
        let guard = self.live.lock().expect("live mutex poisoned");
        let live = guard.as_ref().ok_or(CoreError::Auth { message: "not logged in".into() })?;
        let version = synology_api::pin_version(&live.capabilities, api, desired).unwrap_or(desired);
        Ok((
            Transport::new(&live.connection)?,
            live.session.sid.clone(),
            version,
            live.session.syno_token.clone(),
        ))
    }

    /// Lists every album for `space` by paging `SYNO.Foto.Browse.Album` to
    /// exhaustion. Used by `ensure_trash_album` to find (or confirm the
    /// absence of) the `Recently Deleted` album. Requires a live session.
    async fn list_all_albums(&self, space: Space) -> Result<Vec<Album>, CoreError> {
        let (transport, sid, version, syno_token) = self.write_call_context(browse_album_api(space), 1)?;
        let mut out: Vec<Album> = Vec::new();
        let mut offset = 0u32;
        let limit = 1000u32;
        loop {
            let page =
                synology_api::list_albums(&transport, &sid, space, offset, limit, version, syno_token.as_deref())
                    .await?;
            let n = page.len() as u32;
            out.extend(page);
            if n < limit {
                break;
            }
            offset += limit;
        }
        Ok(out)
    }

    /// The lock-free body of `ensure_trash_album` (owns the album by a
    /// persisted id, never by name; see the public method's doc comment). The
    /// caller MUST already hold `trash_lock`; this helper never acquires it,
    /// so a public trash mutation that delegates here cannot self-deadlock.
    async fn ensure_trash_album_inner(&self, space: Space) -> Result<Album, CoreError> {
        let albums = self.list_all_albums(space).await?;
        if let Some(stored) = self.stored_trash_album_id(space)? {
            if let Some(found) = albums.iter().find(|a| a.id == stored).cloned() {
                self.cache_trash_album_id(space, found.id);
                return Ok(found);
            }
            // Stored id is stale (album deleted on the NAS or by another
            // client): fall through and create a fresh one. Do NOT keep
            // serving the dead id, and do NOT adopt a same-named album.
        }
        let (transport, sid, version, syno_token) = self.write_call_context(normal_album_api(space), 1)?;
        let created =
            synology_api::create_album(&transport, &sid, space, RECENTLY_DELETED_ALBUM, version, syno_token.as_deref())
                .await?;
        self.persist_trash_album_id(space, created.id)?;
        self.cache_trash_album_id(space, created.id);
        Ok(created)
    }

    /// Returns the `Recently Deleted` album id for `space`, using the cached
    /// value if present and otherwise resolving (and caching) it via
    /// `ensure_trash_album_inner`. The caller MUST already hold `trash_lock`
    /// (this is the `_inner` path); it never acquires the lock itself. The
    /// delete/restore paths call this rather than the public
    /// `ensure_trash_album` so a repeat operation does not re-list albums and
    /// so the lock is taken exactly once per public call.
    async fn trash_album_id_inner(&self, space: Space) -> Result<i64, CoreError> {
        if let Some(id) = self.cached_trash_album_id(space) {
            return Ok(id);
        }
        Ok(self.ensure_trash_album_inner(space).await?.id)
    }

    /// Reads the persisted trash-album id for `space` from `app_state`,
    /// parsing it back to an `i64`. A stored value that fails to parse is
    /// treated as "no stored id" (fail closed toward re-resolving) rather than
    /// erroring the whole operation.
    fn stored_trash_album_id(&self, space: Space) -> Result<Option<i64>, CoreError> {
        let guard = self.store.lock().expect("store mutex poisoned");
        let store = guard.as_ref().ok_or_else(store_busy_err)?;
        Ok(store.get_app_state(space, TRASH_ALBUM_ID_KEY)?.and_then(|v| v.parse::<i64>().ok()))
    }

    /// Persists the trash-album id for `space` into `app_state` so the album
    /// is owned by id across restarts.
    fn persist_trash_album_id(&self, space: Space, id: i64) -> Result<(), CoreError> {
        let guard = self.store.lock().expect("store mutex poisoned");
        let store = guard.as_ref().ok_or_else(store_busy_err)?;
        store.set_app_state(space, TRASH_ALBUM_ID_KEY, &id.to_string())
    }

    fn cached_trash_album_id(&self, space: Space) -> Option<i64> {
        self.trash_album_ids.lock().expect("trash album mutex poisoned").get(&space).copied()
    }

    fn cache_trash_album_id(&self, space: Space, id: i64) {
        self.trash_album_ids.lock().expect("trash album mutex poisoned").insert(space, id);
    }

    /// Runs `work` (the sync-engine crawl or reconcile call) against an
    /// owned `Store` without ever holding the `store` mutex guard across an
    /// `.await`.
    ///
    /// `Store` wraps a `RefCell`-based rusqlite statement cache and so is
    /// not `Sync`, which means `&Store` is not `Send`. uniffi's
    /// `async_runtime = "tokio"` export requires every exported `async fn`
    /// to return a `Send` future, so a `Crawler`/`DeltaReconciler` borrowing
    /// `&Store` can never be held live across the `.await` inside that
    /// future - the compiler rejects it outright (confirmed while building
    /// this: holding a locked `&Store` across `crawler.crawl_space(..).await`
    /// fails with "future cannot be sent between threads safely" regardless
    /// of which mutex type guards it).
    ///
    /// The fix is to never let a `Store` borrow cross the outer async
    /// boundary at all: the `store` mutex is locked just long enough to
    /// `take()` the owned `Store` out (`Option<Store>` swap), the guard is
    /// dropped immediately, and the owned `Store` moves onto a dedicated
    /// blocking thread via `spawn_blocking`. There, `Handle::block_on` drives
    /// `work`'s future to completion synchronously - this is the documented,
    /// supported way to run async code from a blocking-pool thread, and it
    /// keeps the whole crawl (including its internal network awaits) on one
    /// thread so `&Store` never needs to be `Send`.
    ///
    /// Guarantee: after this function returns, `self.store` holds `Some` again,
    /// no matter how `work` finished, success, a normal `Err`, or a panic inside
    /// `work` itself. The blocking closure runs `work` behind `catch_unwind` and
    /// always hands the `Store` back in its return tuple, even when `work`
    /// panicked; a caught panic is converted into a `CoreError::Storage` here
    /// rather than being allowed to drop the `Store` on the panicking thread.
    /// So a panicking crawl surfaces as an ordinary error to the caller and
    /// the core stays usable for every call afterward - it never permanently
    /// bricks the store. The mutex is locked twice, once for the initial
    /// take and once for the final swap-back, never across an `.await`.
    async fn run_with_store<F>(&self, work: F) -> Result<CrawlProgress, CoreError>
    where
        F: for<'a> FnOnce(
                &'a Store,
            ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<CrawlProgress, CoreError>> + 'a>>
            + Send
            + 'static,
    {
        let store = {
            let mut guard = self.store.lock().expect("store mutex poisoned");
            guard.take().ok_or_else(store_busy_err)?
        };

        let handle = tokio::runtime::Handle::current();
        let join = tokio::task::spawn_blocking(move || {
            // `store` stays owned in this outer scope for the whole call, so
            // it survives regardless of what happens inside `catch_unwind`.
            // Only a *reference* to it is captured by the inner closure, so
            // a panic there unwinds up to `catch_unwind` and stops - it never
            // drops `store` itself, because `store` was never moved into the
            // unwinding frame. We are only ever handing back a plain owned
            // value afterward, never inspecting any broken invariant of
            // shared state left behind by the panic, so asserting
            // unwind-safety on the borrow is sound even though `Store`
            // doesn't implement `UnwindSafe` itself (its `RefCell`-backed
            // statement cache is what disqualifies it).
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| handle.block_on(work(&store))))
                .unwrap_or_else(|panic| {
                    let message = panic
                        .downcast_ref::<&str>()
                        .map(|s| s.to_string())
                        .or_else(|| panic.downcast_ref::<String>().cloned())
                        .unwrap_or_else(|| "non-string panic payload".to_string());
                    Err(CoreError::Storage { message: format!("crawl/reconcile task panicked: {message}") })
                });
            (store, result)
        })
        .await;

        match join {
            Ok((store, result)) => {
                let mut guard = self.store.lock().expect("store mutex poisoned");
                *guard = Some(store);
                result
            }
            // A panic inside `work` is already caught above and folded into
            // `result` alongside the recovered `Store`, so this arm is only
            // reached by a `JoinError` the blocking task itself never ran to
            // completion for (e.g. the runtime shutting down under it). The
            // `Store` was moved into that still-unresolved task and cannot be
            // recovered here; `store` stays `None` in this one remaining
            // case, which fails closed via `store_busy_err` on later calls.
            Err(e) => Err(CoreError::Storage { message: format!("crawl/reconcile task failed to join: {e}") }),
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn core_version_matches_cargo_pkg_version() {
        assert_eq!(crate::core_version(), env!("CARGO_PKG_VERSION"));
        assert_eq!(crate::core_version(), "0.1.0");
    }
}

#[cfg(test)]
mod core_tests {
    use super::*;

    #[test]
    fn new_opens_store() {
        let dir = std::env::temp_dir().join(format!("photoscore-new-{}", std::process::id()));
        let db = dir.join("db");
        let cache = dir.join("cache");
        std::fs::create_dir_all(&db).unwrap();
        std::fs::create_dir_all(&cache).unwrap();
        let _core = PhotosCore::new(db.to_string_lossy().into(), cache.to_string_lossy().into())
            .expect("core opens");
    }

    fn core_at(label: &str) -> Arc<PhotosCore> {
        let dir = std::env::temp_dir().join(format!("photoscore-{}-{}", label, std::process::id()));
        std::fs::create_dir_all(dir.join("db")).unwrap();
        std::fs::create_dir_all(dir.join("cache")).unwrap();
        PhotosCore::new(dir.join("db").to_string_lossy().into(), dir.join("cache").to_string_lossy().into())
            .expect("core opens")
    }

    #[tokio::test]
    async fn login_stores_live_session() {
        let mut server = mockito::Server::new_async().await;
        let _m = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"sid":"SID-CORE","synotoken":"TK"}}"#)
            .create_async()
            .await;
        let core = core_at("login");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        let session = core
            .login(conn, "photouser".into(), "pw".into(), Some("123456".into()), None)
            .await
            .expect("login ok");
        assert_eq!(session.sid, "SID-CORE");

        // The session is now held in `live`, so a second login (or any
        // authed call) would reuse it rather than starting from None.
        let guard = core.live.lock().unwrap();
        assert!(guard.is_some(), "login must populate Live");
        assert_eq!(guard.as_ref().unwrap().session.sid, "SID-CORE");
    }

    #[tokio::test]
    async fn login_without_otp_when_required_surfaces_otp_required() {
        let mut server = mockito::Server::new_async().await;
        let _m = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":false,"error":{"code":403}}"#)
            .create_async()
            .await;
        let core = core_at("login-otp");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        let err = core
            .login(conn, "photouser".into(), "pw".into(), None, None)
            .await
            .unwrap_err();
        assert!(matches!(err, CoreError::OtpRequired), "got {err:?}");

        // A failed login must not leave stale Live state behind.
        let guard = core.live.lock().unwrap();
        assert!(guard.is_none(), "failed login must not populate Live");
    }

    #[tokio::test]
    async fn restore_session_with_valid_probe_populates_live() {
        let mut server = mockito::Server::new_async().await;
        let _m = server
            .mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{}}"#)
            .create_async()
            .await;
        let core = core_at("restore-valid");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        let session = Session {
            sid: "SID-RESTORE".into(),
            syno_token: None,
            username: "photouser".into(),
            device_did: None,
        };
        let state = core.restore_session(conn, session).await.expect("restore ok");
        assert!(matches!(state, SessionState::Valid), "got {state:?}");
        assert!(core.live.lock().unwrap().is_some());
    }

    #[tokio::test]
    async fn restore_session_with_auth_failure_reports_expired_without_error() {
        let mut server = mockito::Server::new_async().await;
        let _m = server
            .mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":false,"error":{"code":400}}"#)
            .create_async()
            .await;
        let core = core_at("restore-expired");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        let session = Session {
            sid: "SID-STALE".into(),
            syno_token: None,
            username: "photouser".into(),
            device_did: None,
        };
        let state = core.restore_session(conn, session).await.expect("restore does not error on expiry");
        assert!(matches!(state, SessionState::Expired), "got {state:?}");
        assert!(core.live.lock().unwrap().is_none(), "expired restore must not populate Live");
    }

    #[tokio::test]
    async fn sign_out_is_idempotent_without_session() {
        let core = core_at("signout-empty");
        core.sign_out().await.expect("sign_out without a session is a no-op");
        assert!(core.live.lock().unwrap().is_none());
    }

    #[tokio::test]
    async fn probe_capabilities_after_login_caches_and_returns() {
        let mut server = mockito::Server::new_async().await;
        let _login = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"sid":"SID-PROBE"}}"#)
            .create_async()
            .await;
        let _info = server
            .mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(
                r#"{"success":true,"data":{
                    "SYNO.API.Auth":{"minVersion":1,"maxVersion":7,"path":"entry.cgi"},
                    "SYNO.Foto.Browse.Item":{"minVersion":1,"maxVersion":7,"path":"entry.cgi"},
                    "SYNO.Foto.Thumbnail":{"minVersion":1,"maxVersion":2,"path":"entry.cgi"},
                    "SYNO.FotoTeam.Browse.Item":{"minVersion":1,"maxVersion":7,"path":"entry.cgi"}
                }}"#,
            )
            .create_async()
            .await;
        let core = core_at("probe-caps");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "photouser".into(), "pw".into(), None, None).await.expect("login ok");

        let caps = core.probe_capabilities().await.expect("probe ok");
        assert!(caps.iter().any(|c| c.name == "SYNO.Foto.Browse.Item"));
        assert!(caps.iter().any(|c| c.name == "SYNO.Foto.Thumbnail" && c.max_version == 2));
        assert_eq!(caps.len(), 4);

        // The probe must cache the discovered set into Live.capabilities so
        // later version-pinning calls (Tasks 36/37) can read it without a
        // second round trip.
        let guard = core.live.lock().unwrap();
        let cached = &guard.as_ref().unwrap().capabilities;
        assert_eq!(cached.len(), 4);
        assert!(cached.iter().any(|c| c.name == "SYNO.API.Auth"));
    }

    #[tokio::test]
    async fn probe_capabilities_without_login_returns_auth_error() {
        let core = core_at("probe-caps-no-login");
        let err = core.probe_capabilities().await.unwrap_err();
        assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
        assert!(core.live.lock().unwrap().is_none());
    }

    #[tokio::test]
    async fn crawl_space_persists_and_reports_complete() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _info = server.mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"SYNO.Foto.Browse.Item":{"path":"entry.cgi","minVersion":1,"maxVersion":1}}}"#)
            .create_async().await;
        let _list = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("method".into(), "list".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[{"id":1,"filename":"a.jpg","type":"photo","additional":{"thumbnail":{"cache_key":"CK1"}}}]}}"#)
            .create_async().await;
        let dir = std::env::temp_dir().join(format!("photoscore-crawl-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("db")).unwrap();
        std::fs::create_dir_all(dir.join("cache")).unwrap();
        let core = PhotosCore::new(dir.join("db").to_string_lossy().into(), dir.join("cache").to_string_lossy().into()).unwrap();
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "u".into(), "p".into(), None, None).await.unwrap();
        core.probe_capabilities().await.unwrap();

        struct Collector(std::sync::Mutex<Vec<CrawlProgress>>);
        impl FfiCrawlObserver for Collector {
            fn on_progress(&self, p: CrawlProgress) { self.0.lock().unwrap().push(p); }
        }
        let obs = Collector(std::sync::Mutex::new(vec![]));
        let final_p = core.crawl_space(Space::Personal, Box::new(obs)).await.expect("crawl ok");
        assert!(final_p.complete);
        assert_eq!(core.asset_count(Space::Personal).unwrap(), 1);
        assert!(core.crawl_progress(Space::Personal).unwrap().complete);
    }

    /// Proves the crawl cannot be started without a live session: fails
    /// closed with CoreError rather than panicking or hanging.
    #[tokio::test]
    async fn crawl_space_without_login_returns_auth_error() {
        let core = core_at("crawl-no-login");
        struct Collector;
        impl FfiCrawlObserver for Collector {
            fn on_progress(&self, _p: CrawlProgress) {}
        }
        let err = core.crawl_space(Space::Personal, Box::new(Collector)).await.unwrap_err();
        assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
    }

    /// Drives crawl_space to completion end-to-end through a real async
    /// runtime: if `page_source_for` (or anything else in crawl_space) held
    /// the `live`/`store` std Mutex guard across an `.await` point, this
    /// test would deadlock/hang rather than complete, because the crawl's
    /// PageSource call and Store writes both need to run while some other
    /// code path could want the same lock. A passing, terminating test here
    /// is a liveness proof, not just a correctness check.
    #[tokio::test]
    async fn crawl_space_completes_without_deadlock() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _info = server.mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"SYNO.Foto.Browse.Item":{"path":"entry.cgi","minVersion":1,"maxVersion":1}}}"#)
            .create_async().await;
        let _list = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("method".into(), "list".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[{"id":1,"filename":"a.jpg","type":"photo","additional":{"thumbnail":{"cache_key":"CK1"}}}]}}"#)
            .create_async().await;
        let core = core_at("crawl-liveness");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "u".into(), "p".into(), None, None).await.unwrap();
        core.probe_capabilities().await.unwrap();

        struct NoopObserver;
        impl FfiCrawlObserver for NoopObserver {
            fn on_progress(&self, _p: CrawlProgress) {}
        }

        // A generous but finite timeout: if a Mutex guard were held across
        // the crawl's internal .await points, this call would hang forever
        // and the timeout would fire, failing the test instead of the whole
        // suite hanging.
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            core.crawl_space(Space::Personal, Box::new(NoopObserver)),
        )
        .await
        .expect("crawl_space must not deadlock/hang");
        assert!(result.expect("crawl ok").complete);
    }

    /// Regression test for the Store-bricking bug: forces the crawl itself
    /// to panic (via an observer whose `on_progress` panics, called from
    /// inside `Crawler::crawl_space` on the blocking thread), asserts
    /// `crawl_space` surfaces the panic as an ordinary `CoreError` rather
    /// than hanging or aborting the test process, and then asserts a
    /// subsequent call succeeds - proving `run_with_store` actually put the
    /// `Store` back rather than leaving `self.store` permanently `None`.
    #[tokio::test]
    async fn crawl_space_recovers_store_after_panic() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _info = server.mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"SYNO.Foto.Browse.Item":{"path":"entry.cgi","minVersion":1,"maxVersion":1}}}"#)
            .create_async().await;
        let _list = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("method".into(), "list".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[{"id":1,"filename":"a.jpg","type":"photo","additional":{"thumbnail":{"cache_key":"CK1"}}}]}}"#)
            .create_async().await;
        let core = core_at("crawl-panic-recovery");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "u".into(), "p".into(), None, None).await.unwrap();
        core.probe_capabilities().await.unwrap();

        struct PanickingObserver;
        impl FfiCrawlObserver for PanickingObserver {
            fn on_progress(&self, _p: CrawlProgress) {
                panic!("simulated crawl panic");
            }
        }

        // Suppress the default panic backtrace noise for this expected panic
        // so the test output stays readable; restore it afterward.
        let default_hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(|_| {}));
        let panicked = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            core.crawl_space(Space::Personal, Box::new(PanickingObserver)),
        )
        .await
        .expect("crawl_space must not hang when the crawl panics");
        std::panic::set_hook(default_hook);

        let err = panicked.expect_err("a panicking crawl must surface as an Err, not a hang");
        assert!(matches!(err, CoreError::Storage { .. }), "got {err:?}");

        // The real assertion: the Store must have been put back. If it
        // weren't, every call below would fail with the "store busy" error
        // forever instead of succeeding. (The single page was already
        // upserted before the observer callback panicked, so the asset is
        // present; what matters here is that the read succeeds at all.)
        let count = core.asset_count(Space::Personal).expect("store must be usable again after the panic");
        assert_eq!(count, 1);
        let progress = core.crawl_progress(Space::Personal).expect("progress read must succeed after the panic");
        assert!(progress.complete, "the crawl had already persisted the completing page before the panic");

        // And a fresh crawl on the same core must work end to end, proving
        // the recovered Store is not just readable but fully functional.
        struct NoopObserver;
        impl FfiCrawlObserver for NoopObserver {
            fn on_progress(&self, _p: CrawlProgress) {}
        }
        let retried = core.crawl_space(Space::Personal, Box::new(NoopObserver)).await.expect("retry crawl ok");
        assert!(retried.complete);
        assert_eq!(core.asset_count(Space::Personal).unwrap(), 1);
    }

    #[tokio::test]
    async fn reconcile_delta_runs_after_crawl() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _info = server.mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"SYNO.Foto.Browse.Item":{"path":"entry.cgi","minVersion":1,"maxVersion":1}}}"#)
            .create_async().await;
        let _list = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("method".into(), "list".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[{"id":1,"filename":"a.jpg","type":"photo","additional":{"thumbnail":{"cache_key":"CK1"}}}]}}"#)
            .create_async().await;
        let core = core_at("reconcile");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "u".into(), "p".into(), None, None).await.unwrap();
        core.probe_capabilities().await.unwrap();

        struct NoopObserver;
        impl FfiCrawlObserver for NoopObserver {
            fn on_progress(&self, _p: CrawlProgress) {}
        }
        core.crawl_space(Space::Personal, Box::new(NoopObserver)).await.expect("crawl ok");

        let progress = core.reconcile_delta(Space::Personal).await.expect("reconcile ok");
        assert_eq!(progress.done, 1);
        assert_eq!(core.asset_count(Space::Personal).unwrap(), 1);
    }

    #[tokio::test]
    async fn crawl_progress_without_any_crawl_reports_zero_incomplete() {
        let core = core_at("progress-empty");
        let progress = core.crawl_progress(Space::Personal).expect("progress read ok");
        assert!(!progress.complete);
        assert_eq!(progress.done, 0);
    }

    /// Task 36 brief's exact TDD test: on a freshly opened, never-logged-in
    /// core, the three local read methods all succeed (no auth required) and
    /// report empty/zero rather than erroring.
    #[test]
    fn fetch_assets_and_count_are_local_reads() {
        let dir = std::env::temp_dir().join(format!("photoscore-fetch-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("db")).unwrap();
        std::fs::create_dir_all(dir.join("cache")).unwrap();
        let core = PhotosCore::new(dir.join("db").to_string_lossy().into(), dir.join("cache").to_string_lossy().into()).unwrap();
        assert_eq!(core.asset_count(Space::Personal).unwrap(), 0);
        assert!(core.fetch_assets(Space::Personal, 0, 10).unwrap().is_empty());
        assert!(core.fetch_local_albums(Space::Personal).unwrap().is_empty());
    }

    /// Proves fetch_assets/fetch_local_albums actually delegate to the Store's real
    /// windowed queries rather than being stubs: upserts assets/albums across
    /// both spaces directly via the Store, then checks the core-level reads
    /// return the right rows, the right order, the right window, and never
    /// leak across spaces.
    #[test]
    fn fetch_assets_and_albums_return_upserted_rows_windowed_and_space_scoped() {
        let dir = std::env::temp_dir().join(format!("photoscore-fetch-data-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("db")).unwrap();
        std::fs::create_dir_all(dir.join("cache")).unwrap();
        let core = PhotosCore::new(dir.join("db").to_string_lossy().into(), dir.join("cache").to_string_lossy().into()).unwrap();

        {
            let guard = core.store.lock().unwrap();
            let store = guard.as_ref().unwrap();
            for id in 1..=5 {
                store
                    .upsert_asset(&Asset {
                        id,
                        unit_id: id + 5000,
                        cache_key: format!("ck{id}"),
                        filename: format!("IMG_{id}.jpg"),
                        media_kind: models::MediaKind::Photo,
                        taken_at: Some(id * 10),
                        added_at: Some(1000),
                        width: Some(4000),
                        height: Some(3000),
                        file_size: Some(2_000_000),
                        space: Space::Personal,
                        server_version: Some(1),
                        ..Default::default()
                    })
                    .unwrap();
            }
            store
                .upsert_asset(&Asset {
                    id: 99,
                    unit_id: 5099,
                    cache_key: "ck99".into(),
                    filename: "shared.jpg".into(),
                    media_kind: models::MediaKind::Photo,
                    taken_at: Some(500),
                    added_at: Some(1000),
                    width: None,
                    height: None,
                    file_size: None,
                    space: Space::Shared,
                    server_version: Some(1),
                    ..Default::default()
                })
                .unwrap();
            store
                .upsert_album(&models::Album {
                    id: 1,
                    name: "Trip".into(),
                    item_count: 3,
                    cover_cache_key: Some("cover1".into()),
                    cover_unit_id: None,
                    is_shared: false,
                    is_smart: false,
                    space: Space::Personal,
                })
                .unwrap();
            store
                .upsert_album(&models::Album {
                    id: 2,
                    name: "SharedAlbum".into(),
                    item_count: 1,
                    cover_cache_key: None,
                    cover_unit_id: None,
                    is_shared: false,
                    is_smart: false,
                    space: Space::Shared,
                })
                .unwrap();
        }

        assert_eq!(core.asset_count(Space::Personal).unwrap(), 5);
        assert_eq!(core.asset_count(Space::Shared).unwrap(), 1);

        // Newest-first (by taken_at), windowed by offset/limit.
        let first_page = core.fetch_assets(Space::Personal, 0, 2).unwrap();
        assert_eq!(first_page.iter().map(|a| a.id).collect::<Vec<_>>(), vec![5, 4]);
        let second_page = core.fetch_assets(Space::Personal, 2, 2).unwrap();
        assert_eq!(second_page.iter().map(|a| a.id).collect::<Vec<_>>(), vec![3, 2]);

        // Space isolation: Personal reads never see the Shared asset.
        assert!(core.fetch_assets(Space::Personal, 0, 100).unwrap().iter().all(|a| a.id != 99));
        let shared_assets = core.fetch_assets(Space::Shared, 0, 100).unwrap();
        assert_eq!(shared_assets.len(), 1);
        assert_eq!(shared_assets[0].id, 99);

        let personal_albums = core.fetch_local_albums(Space::Personal).unwrap();
        assert_eq!(personal_albums.len(), 1);
        assert_eq!(personal_albums[0].name, "Trip");
        let shared_albums = core.fetch_local_albums(Space::Shared).unwrap();
        assert_eq!(shared_albums.len(), 1);
        assert_eq!(shared_albums[0].name, "SharedAlbum");
    }

    /// Fail-closed proof: if the Store has been taken out of the mutex (the
    /// same window a crawl/reconcile briefly holds via `run_with_store`),
    /// every local read method must return `CoreError::Storage` rather than
    /// panicking on an `Option::unwrap`.
    #[test]
    fn local_reads_fail_closed_when_store_is_busy() {
        let core = core_at("fetch-busy");
        let taken = core.store.lock().unwrap().take();
        assert!(taken.is_some(), "test setup: store must have been Some before taking it");

        let count_err = core.asset_count(Space::Personal).unwrap_err();
        assert!(matches!(count_err, CoreError::Storage { .. }), "got {count_err:?}");

        let fetch_err = core.fetch_assets(Space::Personal, 0, 10).unwrap_err();
        assert!(matches!(fetch_err, CoreError::Storage { .. }), "got {fetch_err:?}");

        let albums_err = core.fetch_local_albums(Space::Personal).unwrap_err();
        assert!(matches!(albums_err, CoreError::Storage { .. }), "got {albums_err:?}");

        // Put the store back so nothing else in the process is left bricked.
        *core.store.lock().unwrap() = taken;
    }

    #[tokio::test]
    async fn sign_out_clears_live_after_login() {
        let mut server = mockito::Server::new_async().await;
        let _login = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"sid":"SID-OUT"}}"#)
            .create_async()
            .await;
        let _logout = server
            .mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("method".into(), "logout".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{}}"#)
            .create_async()
            .await;
        let core = core_at("signout-live");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "photouser".into(), "pw".into(), None, None).await.expect("login ok");
        assert!(core.live.lock().unwrap().is_some());

        core.sign_out().await.expect("sign_out ok");
        assert!(core.live.lock().unwrap().is_none(), "sign_out must clear Live");
    }

    /// Task 37 TDD: a thumbnail cache miss fetches the bytes over the network,
    /// writes them to the composite-key cache path, and returns both the path
    /// and the bytes.
    #[tokio::test]
    async fn thumbnail_cache_miss_fetches_and_writes_cache_file() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _info = server.mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"SYNO.Foto.Thumbnail":{"path":"entry.cgi","minVersion":1,"maxVersion":2}}}"#)
            .create_async().await;
        let _thumb = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Thumbnail".into()),
                mockito::Matcher::UrlEncoded("id".into(), "101".into()),
                mockito::Matcher::UrlEncoded("cache_key".into(), "CK1".into()),
            ]))
            .with_status(200).with_header("content-type", "image/jpeg")
            .with_body(vec![0xFF, 0xD8, 0xFF])
            .expect(1)
            .create_async().await;
        let core = core_at("thumb-miss");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "u".into(), "p".into(), None, None).await.unwrap();
        core.probe_capabilities().await.unwrap();

        let data = core.thumbnail(Space::Personal, 101, "CK1".into(), models::ThumbnailSize::Sm).await.expect("thumb ok");
        assert!(data.cached_path.contains("thumbs"));
        assert!(data.cached_path.ends_with(".jpg"));
        assert!(std::path::Path::new(&data.cached_path).exists());
        assert_eq!(data.bytes, vec![0xFF, 0xD8, 0xFF]);
        _thumb.assert_async().await;
    }

    /// Task 37 TDD: a second call with the SAME composite key (space, asset,
    /// size, cache_key) must be served entirely from disk, without a second
    /// network round trip. Proven by asserting the thumbnail mock received
    /// exactly one call total across both `thumbnail()` invocations.
    #[tokio::test]
    async fn thumbnail_cache_hit_skips_network() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _info = server.mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"SYNO.Foto.Thumbnail":{"path":"entry.cgi","minVersion":1,"maxVersion":2}}}"#)
            .create_async().await;
        let _thumb = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Thumbnail".into()),
                mockito::Matcher::UrlEncoded("id".into(), "202".into()),
                mockito::Matcher::UrlEncoded("cache_key".into(), "CK2".into()),
            ]))
            .with_status(200).with_header("content-type", "image/jpeg")
            .with_body(vec![0xAA, 0xBB])
            .expect(1)
            .create_async().await;
        let core = core_at("thumb-hit");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "u".into(), "p".into(), None, None).await.unwrap();
        core.probe_capabilities().await.unwrap();

        let first = core.thumbnail(Space::Personal, 202, "CK2".into(), models::ThumbnailSize::M).await.expect("first ok");
        let second = core.thumbnail(Space::Personal, 202, "CK2".into(), models::ThumbnailSize::M).await.expect("second ok");
        assert_eq!(first.cached_path, second.cached_path);
        assert_eq!(second.bytes, vec![0xAA, 0xBB]);
        // The mock is `.expect(1)`: if the cache hit had reached the network
        // again, `.assert_async()` below would fail.
        _thumb.assert_async().await;
    }

    /// Task 37 TDD: a DIFFERENT cache_key for the same asset/size must miss
    /// the cache and re-fetch, proving the composite key includes cache_key
    /// rather than just (space, asset_id, size).
    #[tokio::test]
    async fn thumbnail_different_cache_key_invalidates_and_refetches() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _info = server.mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"SYNO.Foto.Thumbnail":{"path":"entry.cgi","minVersion":1,"maxVersion":2}}}"#)
            .create_async().await;
        let _thumb_ck1 = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Thumbnail".into()),
                mockito::Matcher::UrlEncoded("id".into(), "303".into()),
                mockito::Matcher::UrlEncoded("cache_key".into(), "CK-OLD".into()),
            ]))
            .with_status(200).with_header("content-type", "image/jpeg")
            .with_body(vec![0x01])
            .expect(1)
            .create_async().await;
        let _thumb_ck2 = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Thumbnail".into()),
                mockito::Matcher::UrlEncoded("id".into(), "303".into()),
                mockito::Matcher::UrlEncoded("cache_key".into(), "CK-NEW".into()),
            ]))
            .with_status(200).with_header("content-type", "image/jpeg")
            .with_body(vec![0x02])
            .expect(1)
            .create_async().await;
        let core = core_at("thumb-invalidate");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "u".into(), "p".into(), None, None).await.unwrap();
        core.probe_capabilities().await.unwrap();

        let old = core.thumbnail(Space::Personal, 303, "CK-OLD".into(), models::ThumbnailSize::Xl).await.expect("old ok");
        let new = core.thumbnail(Space::Personal, 303, "CK-NEW".into(), models::ThumbnailSize::Xl).await.expect("new ok");
        assert_ne!(old.cached_path, new.cached_path, "a changed cache_key must produce a distinct cache path");
        assert_eq!(old.bytes, vec![0x01]);
        assert_eq!(new.bytes, vec![0x02]);
        _thumb_ck1.assert_async().await;
        _thumb_ck2.assert_async().await;
    }

    /// Security fix: a `cache_key` containing path-traversal/path-separator
    /// bytes (as could arrive from a malformed or malicious NAS response)
    /// must not escape the cache directory. The filename is a hash of the
    /// composite key, so the raw `cache_key` never appears literally in the
    /// path; the resulting file's parent directory must still be exactly
    /// `{cache_dir}/thumbs`, and the fetch must still succeed (a hit/miss on
    /// the hashed path, not a filesystem error or an escape).
    #[tokio::test]
    async fn thumbnail_cache_key_with_path_traversal_stays_inside_cache_dir() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _info = server.mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"SYNO.Foto.Thumbnail":{"path":"entry.cgi","minVersion":1,"maxVersion":2}}}"#)
            .create_async().await;
        let malicious_key = "../../../../../../tmp/evil";
        let _thumb = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Thumbnail".into()),
                mockito::Matcher::UrlEncoded("id".into(), "404".into()),
                mockito::Matcher::UrlEncoded("cache_key".into(), malicious_key.into()),
            ]))
            .with_status(200).with_header("content-type", "image/jpeg")
            .with_body(vec![0x99])
            .expect(1)
            .create_async().await;
        let core = core_at("thumb-traversal");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "u".into(), "p".into(), None, None).await.unwrap();
        core.probe_capabilities().await.unwrap();

        let data = core
            .thumbnail(Space::Personal, 404, malicious_key.into(), models::ThumbnailSize::Sm)
            .await
            .expect("thumb ok even with a hostile cache_key");
        assert_eq!(data.bytes, vec![0x99]);

        let written = std::path::Path::new(&data.cached_path);
        assert!(written.exists(), "cache file must exist at the returned path");
        let expected_dir = std::path::Path::new(&core.cache_dir).join("thumbs");
        assert_eq!(
            written.parent().unwrap().canonicalize().unwrap(),
            expected_dir.canonicalize().unwrap(),
            "cache_key must never be able to steer the file outside {{cache_dir}}/thumbs"
        );
        // The raw cache_key must never appear literally in the path: proof
        // that the filename is derived from a hash, not string interpolation.
        assert!(!data.cached_path.contains(".."), "path must not contain traversal segments");
        assert!(
            !data.cached_path.contains("evil"),
            "the raw cache_key content must not appear literally in the cache path"
        );
        _thumb.assert_async().await;
    }

    /// Task 37 TDD: fail-closed when no session is held; no network hit.
    #[tokio::test]
    async fn thumbnail_without_login_returns_auth_error() {
        let core = core_at("thumb-no-login");
        let err = core.thumbnail(Space::Personal, 1, "CK".into(), models::ThumbnailSize::Sm).await.unwrap_err();
        assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
    }

    /// Task 37 TDD: download_original fetches full-resolution bytes and
    /// writes them to a path it returns; read-only, no NAS write.
    #[tokio::test]
    async fn download_original_returns_path_to_downloaded_bytes() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _info = server.mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"SYNO.Foto.Download":{"path":"entry.cgi","minVersion":1,"maxVersion":2}}}"#)
            .create_async().await;
        let _dl = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Download".into()),
                mockito::Matcher::UrlEncoded("method".into(), "download".into()),
            ]))
            .with_status(200).with_header("content-type", "application/octet-stream")
            .with_body(b"ORIGINAL-BYTES".to_vec())
            .create_async().await;
        let core = core_at("download-ok");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "u".into(), "p".into(), None, None).await.unwrap();
        core.probe_capabilities().await.unwrap();

        let path = core.download_original(Space::Personal, 101, "CK1".into()).await.expect("download ok");
        assert!(std::path::Path::new(&path).exists());
        let bytes = std::fs::read(&path).unwrap();
        assert_eq!(bytes, b"ORIGINAL-BYTES".to_vec());
    }

    /// Task 37 TDD: a JSON error envelope from the download endpoint maps to
    /// a CoreError via `map_binary_or_error`, not a panic or silent success.
    #[tokio::test]
    async fn download_original_json_error_maps_to_core_error() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _info = server.mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"SYNO.Foto.Download":{"path":"entry.cgi","minVersion":1,"maxVersion":2}}}"#)
            .create_async().await;
        let _dl = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Download".into()),
                mockito::Matcher::UrlEncoded("method".into(), "download".into()),
            ]))
            .with_status(200).with_header("content-type", "application/json")
            .with_body(r#"{"success":false,"error":{"code":400}}"#)
            .create_async().await;
        let core = core_at("download-err");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "u".into(), "p".into(), None, None).await.unwrap();
        core.probe_capabilities().await.unwrap();

        let err = core.download_original(Space::Personal, 101, "CK1".into()).await.unwrap_err();
        assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
    }

    /// Task 37 TDD: fail-closed when no session is held; no network hit.
    #[tokio::test]
    async fn download_original_without_login_returns_auth_error() {
        let core = core_at("download-no-login");
        let err = core.download_original(Space::Personal, 1, "CK".into()).await.unwrap_err();
        assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
    }

    fn video_asset(unit_id: i64, cache_key: &str) -> Asset {
        Asset {
            id: unit_id - 5000,
            unit_id,
            cache_key: cache_key.to_string(),
            filename: "IMG_0100.MOV".to_string(),
            media_kind: models::MediaKind::Video,
            taken_at: Some(1_700_000_000),
            added_at: None,
            width: Some(1920),
            height: Some(1080),
            file_size: Some(10_000_000),
            space: Space::Personal,
            server_version: Some(1),
            ..Default::default()
        }
    }

    /// video_playback_source downloads the original the same way
    /// download_original does and reports it back as LocalFile, the
    /// confirmed approach per the probe findings (no working Streaming
    /// method was found on the real NAS).
    #[tokio::test]
    async fn video_playback_source_returns_local_file_for_downloaded_bytes() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _info = server.mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"SYNO.Foto.Download":{"path":"entry.cgi","minVersion":1,"maxVersion":2}}}"#)
            .create_async().await;
        let _dl = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Download".into()),
                mockito::Matcher::UrlEncoded("method".into(), "download".into()),
            ]))
            .with_status(200).with_header("content-type", "video/quicktime")
            .with_body(b"FAKE-MOV-BYTES".to_vec())
            .create_async().await;
        let core = core_at("video-playback-ok");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "u".into(), "p".into(), None, None).await.unwrap();
        core.probe_capabilities().await.unwrap();

        let asset = video_asset(202, "CK-VIDEO");
        let source = core.video_playback_source(Space::Personal, asset).await.expect("video playback source ok");
        match source {
            VideoPlaybackSource::LocalFile { path } => {
                assert!(std::path::Path::new(&path).exists());
                let bytes = std::fs::read(&path).unwrap();
                assert_eq!(bytes, b"FAKE-MOV-BYTES".to_vec());
            }
            VideoPlaybackSource::Url { url } => panic!("expected LocalFile, got Url({url})"),
        }
    }

    /// A download failure (JSON error envelope) propagates through
    /// video_playback_source exactly like it does through download_original,
    /// rather than being swallowed or turned into a different error shape.
    #[tokio::test]
    async fn video_playback_source_propagates_download_error() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _info = server.mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"SYNO.Foto.Download":{"path":"entry.cgi","minVersion":1,"maxVersion":2}}}"#)
            .create_async().await;
        let _dl = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Download".into()),
                mockito::Matcher::UrlEncoded("method".into(), "download".into()),
            ]))
            .with_status(200).with_header("content-type", "application/json")
            .with_body(r#"{"success":false,"error":{"code":400}}"#)
            .create_async().await;
        let core = core_at("video-playback-err");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "u".into(), "p".into(), None, None).await.unwrap();
        core.probe_capabilities().await.unwrap();

        let asset = video_asset(202, "CK-VIDEO");
        let err = core.video_playback_source(Space::Personal, asset).await.unwrap_err();
        assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
    }

    /// Fail-closed when no session is held; no network hit, same discipline
    /// as download_original_without_login_returns_auth_error.
    #[tokio::test]
    async fn video_playback_source_without_login_returns_auth_error() {
        let core = core_at("video-playback-no-login");
        let asset = video_asset(1, "CK");
        let err = core.video_playback_source(Space::Personal, asset).await.unwrap_err();
        assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
    }

    /// The FFI surface the Swift UI will call for trust-on-first-use: given a
    /// bare host, `fetch_certificate` returns a `CertInfo` with the DER, a
    /// 64-hex-char SHA-256 fingerprint, and a subject string, with no session
    /// required at all (this can be called before any login).
    #[tokio::test]
    async fn fetch_certificate_returns_cert_info_for_a_real_tls_server() {
        let rcgen::CertifiedKey { cert, signing_key } =
            rcgen::generate_simple_self_signed(vec!["127.0.0.1".to_string()]).expect("self-signed cert generates");
        let cert_der = cert.der().to_vec();
        let key_der = signing_key.serialize_der();
        let server_config = rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(
                vec![rustls_pki_types::CertificateDer::from(cert_der.clone())],
                rustls_pki_types::PrivateKeyDer::try_from(key_der).expect("key parses"),
            )
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

        let core = core_at("fetch-cert");
        let info = core
            .fetch_certificate(format!("{}:{}", addr.ip(), addr.port()))
            .await
            .expect("fetch_certificate should succeed against a real TLS server");
        assert_eq!(info.der, cert_der);
        assert_eq!(info.sha256_hex.len(), 64);
        assert!(!info.subject.is_empty());
    }

    /// End-to-end (through `PhotosCore::login`, not just `synology_api::auth`
    /// directly): a login with otp captures the device token onto the
    /// returned `Session`, and passing that token back into a later `login`
    /// call succeeds without supplying otp again.
    #[tokio::test]
    async fn login_round_trips_device_token_through_the_core_facade() {
        let mut server = mockito::Server::new_async().await;
        let _first = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("otp_code=999999".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"sid":"SID-1","did":"CORE-DEVICE-TOKEN"}}"#)
            .create_async()
            .await;
        let core = core_at("device-token-roundtrip");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        let session = core
            .login(conn.clone(), "photouser".into(), "pw".into(), Some("999999".into()), None)
            .await
            .expect("first login with otp ok");
        assert_eq!(session.device_did.as_deref(), Some("CORE-DEVICE-TOKEN"));

        // Trap: the second login must not need to send otp_code again.
        let _trap = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("otp_code".into()))
            .expect(0)
            .create_async()
            .await;
        let _second = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("did=CORE-DEVICE-TOKEN".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"sid":"SID-2"}}"#)
            .create_async()
            .await;
        let session2 = core
            .login(conn, "photouser".into(), "pw".into(), None, session.device_did.clone())
            .await
            .expect("second login with stored device token should succeed without otp");
        assert_eq!(session2.sid, "SID-2");
        _trap.assert_async().await;
    }

    /// Logs a core in against `server` with a trivial capability probe so
    /// `discovery_call_context` has a `Live` to read. Shared by every
    /// discovery-facade test below.
    async fn logged_in_core(label: &str, server: &mockito::ServerGuard) -> Arc<PhotosCore> {
        let core = core_at(label);
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "u".into(), "p".into(), None, None).await.expect("login ok");
        core
    }

    #[tokio::test]
    async fn fetch_people_hits_the_nas_and_returns_real_shape() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _people = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Browse.Person".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[{"cover":39646,"id":12279,"item_count":23,"name":"","show":true}]}}"#)
            .create_async().await;
        let core = logged_in_core("fetch-people", &server).await;
        let people = core.fetch_people(0, 50).await.expect("fetch_people ok");
        assert_eq!(people.len(), 1);
        assert_eq!(people[0].id, 12279);
        assert!(people[0].name.is_empty());
    }

    #[tokio::test]
    async fn fetch_places_hits_the_nas_and_returns_real_shape() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _places = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Browse.Geocoding".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[{"country":"Norway","country_id":1,"first_level":"Oslo","id":762,"item_count":10,"name":"Grunerlokka, Oslo","second_level":"Grunerlokka"}]}}"#)
            .create_async().await;
        let core = logged_in_core("fetch-places", &server).await;
        let places = core.fetch_places(0, 50).await.expect("fetch_places ok");
        assert_eq!(places.len(), 1);
        assert_eq!(places[0].country, "Norway");
    }

    #[tokio::test]
    async fn fetch_subjects_hits_the_nas_and_returns_real_shape() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _concept = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Browse.Concept".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[{"display_threshold":1,"id":103,"item_count":2,"name":"Food","sort_index":10,"visibility":true}]}}"#)
            .create_async().await;
        let core = logged_in_core("fetch-subjects", &server).await;
        let subjects = core.fetch_subjects(0, 50).await.expect("fetch_subjects ok");
        assert_eq!(subjects.len(), 1);
        assert_eq!(subjects[0].name, "Food");
    }

    #[tokio::test]
    async fn fetch_tags_returns_empty_list_cleanly() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _tags = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Browse.GeneralTag".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[]}}"#)
            .create_async().await;
        let core = logged_in_core("fetch-tags", &server).await;
        let tags = core.fetch_tags(0, 50).await.expect("fetch_tags ok");
        assert!(tags.is_empty(), "no tags exist yet on this NAS; must decode to an empty list, not error");
    }

    #[tokio::test]
    async fn fetch_assets_for_person_sends_bare_int_person_id() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _filtered = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Browse.Item".into()),
                mockito::Matcher::UrlEncoded("person_id".into(), "12279".into()),
            ]))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[{"id":73501,"filename":"IMG_1664.JPG","type":"photo","additional":{"thumbnail":{"cache_key":"CK1","unit_id":55847}}}]}}"#)
            .create_async().await;
        let core = logged_in_core("fetch-assets-for-person", &server).await;
        let assets = core
            .fetch_assets_for(DiscoveryCollection::Person { id: 12279 }, 0, 50)
            .await
            .expect("fetch_assets_for person ok");
        assert_eq!(assets.len(), 1);
        assert_eq!(assets[0].unit_id, 55847);
    }

    #[tokio::test]
    async fn fetch_assets_for_favorites_sends_favorite_true() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _filtered = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("favorite".into(), "true".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[{"id":73459,"filename":"IMG_1910.JPG","type":"photo","additional":{"thumbnail":{"cache_key":"CK3","unit_id":55805}}}]}}"#)
            .create_async().await;
        let core = logged_in_core("fetch-assets-for-favorites", &server).await;
        let assets = core
            .fetch_assets_for(DiscoveryCollection::Favorites, 0, 50)
            .await
            .expect("fetch_assets_for favorites ok");
        assert_eq!(assets.len(), 1);
    }

    #[tokio::test]
    async fn search_assets_sends_list_item_method_and_keyword_param() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _search = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Search.Search".into()),
                mockito::Matcher::UrlEncoded("method".into(), "list_item".into()),
                mockito::Matcher::UrlEncoded("keyword".into(), "food".into()),
            ]))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[{"id":73507,"filename":"IMG_1619.JPG","type":"live","additional":{"thumbnail":{"cache_key":"55853_1480101974","unit_id":55853}}}]}}"#)
            .create_async().await;
        let core = logged_in_core("search-assets", &server).await;
        let assets = core.search_assets("food".to_string(), 0, 50).await.expect("search_assets ok");
        assert_eq!(assets.len(), 1);
        assert_eq!(assets[0].unit_id, 55853);
    }

    #[tokio::test]
    async fn search_assets_returns_empty_list_cleanly_on_no_match() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _search = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("keyword".into(), "zzzznosuchthing123".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[]}}"#)
            .create_async().await;
        let core = logged_in_core("search-assets-empty", &server).await;
        let assets = core.search_assets("zzzznosuchthing123".to_string(), 0, 50).await.expect("search_assets ok");
        assert!(assets.is_empty(), "a keyword with no matches must decode to an empty list, not error");
    }

    #[tokio::test]
    async fn search_assets_filtered_sends_start_and_end_time() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _search = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Search.Search".into()),
                mockito::Matcher::UrlEncoded("keyword".into(), "IMG".into()),
                mockito::Matcher::UrlEncoded("start_time".into(), "1400000000".into()),
                mockito::Matcher::UrlEncoded("end_time".into(), "1500000000".into()),
            ]))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[{"id":73459,"filename":"IMG_1910.JPG","type":"photo","additional":{"thumbnail":{"cache_key":"CK1","unit_id":1001}}}]}}"#)
            .create_async().await;
        let core = logged_in_core("search-assets-filtered", &server).await;
        let filters = SearchFilters { start_time: Some(1_400_000_000), end_time: Some(1_500_000_000) };
        let assets = core
            .search_assets_filtered("IMG".to_string(), filters, 0, 50)
            .await
            .expect("search_assets_filtered ok");
        assert_eq!(assets.len(), 1);
        assert_eq!(assets[0].unit_id, 1001);
    }

    #[tokio::test]
    async fn search_assets_filtered_with_default_filters_matches_plain_search() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _search = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("keyword".into(), "IMG".into()),
            ]))
            .match_request(|req| !req.path_and_query().contains("start_time") && !req.path_and_query().contains("end_time"))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[]}}"#)
            .create_async().await;
        let core = logged_in_core("search-assets-filtered-default", &server).await;
        let assets = core
            .search_assets_filtered("IMG".to_string(), SearchFilters::default(), 0, 50)
            .await
            .expect("search_assets_filtered ok");
        assert!(assets.is_empty());
    }

    #[tokio::test]
    async fn search_assets_filtered_without_login_returns_auth_error() {
        let core = core_at("search-assets-filtered-no-login");
        let err = core
            .search_assets_filtered("IMG".to_string(), SearchFilters::default(), 0, 50)
            .await
            .unwrap_err();
        assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
    }

    #[tokio::test]
    async fn fetch_search_facets_hits_the_nas_and_returns_real_shape() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _filter = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Search.Filter".into()),
                mockito::Matcher::UrlEncoded("method".into(), "list".into()),
            ]))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{
                "aperture":[{"id":1,"name":"F1.8"}],
                "camera":[{"id":23,"name":"iPhone 6s"}],
                "geocoding":[{"children":[],"id":1,"level":1,"name":"Norway"}],
                "item_type":[{"id":0,"name":"photo"}]
            }}"#)
            .create_async().await;
        let core = logged_in_core("fetch-search-facets", &server).await;
        let facets = core.fetch_search_facets().await.expect("fetch_search_facets ok");
        assert_eq!(facets.cameras.len(), 1);
        assert_eq!(facets.cameras[0].name, "iPhone 6s");
        assert_eq!(facets.apertures[0].name, "F1.8");
        assert_eq!(facets.geocodings[0].name, "Norway");
        assert_eq!(facets.media_types[0].name, "photo");
    }

    #[tokio::test]
    async fn fetch_search_facets_without_login_returns_auth_error() {
        let core = core_at("fetch-search-facets-no-login");
        let err = core.fetch_search_facets().await.unwrap_err();
        assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
    }

    #[tokio::test]
    async fn fetch_people_without_login_returns_auth_error() {
        let core = core_at("fetch-people-no-login");
        let err = core.fetch_people(0, 50).await.unwrap_err();
        assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
    }

    #[tokio::test]
    async fn fetch_assets_for_without_login_returns_auth_error() {
        let core = core_at("fetch-assets-for-no-login");
        let err = core.fetch_assets_for(DiscoveryCollection::Favorites, 0, 50).await.unwrap_err();
        assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
    }

    #[tokio::test]
    async fn search_assets_without_login_returns_auth_error() {
        let core = core_at("search-assets-no-login");
        let err = core.search_assets("food".to_string(), 0, 50).await.unwrap_err();
        assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
    }

    // --- Phase 2a: hybrid safe delete facade ----------------------------

    /// Upserts one non-trashed asset directly into the local store, so the
    /// delete/restore tests have a real library row to move around.
    fn seed_asset(core: &PhotosCore, space: Space, id: i64) {
        let guard = core.store.lock().unwrap();
        let store = guard.as_ref().unwrap();
        store
            .upsert_asset(&Asset {
                id,
                unit_id: id + 5000,
                cache_key: format!("ck{id}"),
                filename: format!("IMG_{id}.jpg"),
                media_kind: models::MediaKind::Photo,
                taken_at: Some(id * 10),
                added_at: Some(1000),
                width: None,
                height: None,
                file_size: None,
                space,
                server_version: Some(1),
                ..Default::default()
            })
            .unwrap();
    }

    /// Seeds an asset already flagged as trashed (bypassing the network),
    /// used by the restore and permanent-delete tests.
    fn seed_trashed_asset(core: &PhotosCore, space: Space, id: i64) {
        seed_asset(core, space, id);
        let guard = core.store.lock().unwrap();
        let store = guard.as_ref().unwrap();
        store.set_trash_flag(space, &[id], true, Some(1000)).unwrap();
    }

    /// Persists the app's trash-album id for `space`, so a test exercises the
    /// "own the album by stored id" path (FIX A) without first calling the
    /// create flow.
    fn seed_trash_album_id(core: &PhotosCore, space: Space, id: i64) {
        let guard = core.store.lock().unwrap();
        let store = guard.as_ref().unwrap();
        store.set_app_state(space, super::TRASH_ALBUM_ID_KEY, &id.to_string()).unwrap();
    }

    /// Mock a `Browse.Album` `list` returning `body` (the album list JSON).
    fn mock_album_list(server: &mut mockito::ServerGuard, body: &'static str) -> mockito::Mock {
        server
            .mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Browse.Album".into()),
                mockito::Matcher::UrlEncoded("method".into(), "list".into()),
            ]))
            .with_status(200)
            .with_body(body)
            .create()
    }

    #[tokio::test]
    async fn delete_to_trash_moves_asset_out_of_library_into_trash() {
        let mut server = mockito::Server::new_async().await;
        let _login = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"sid":"S"}}"#)
            .create_async()
            .await;
        let _albums = mock_album_list(
            &mut server,
            r#"{"success":true,"data":{"list":[{"id":500,"name":"Recently Deleted","item_count":0}]}}"#,
        );
        let _add = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::AllOf(vec![
                mockito::Matcher::Regex("api=SYNO.Foto.Browse.NormalAlbum".into()),
                mockito::Matcher::Regex("method=add_item".into()),
                mockito::Matcher::Regex("id=500".into()),
            ]))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"error_list":[]}}"#)
            .create_async()
            .await;

        let core = logged_in_core("delete-to-trash", &server).await;
        seed_trash_album_id(&core, Space::Personal, 500);
        seed_asset(&core, Space::Personal, 1);
        assert_eq!(core.asset_count(Space::Personal).unwrap(), 1);

        core.delete_to_trash(Space::Personal, vec![1]).await.expect("delete_to_trash ok");

        assert_eq!(core.asset_count(Space::Personal).unwrap(), 0, "trashed asset leaves the library");
        assert!(core.fetch_assets(Space::Personal, 0, 10).unwrap().is_empty());
        let trash: Vec<i64> = core.fetch_trash(Space::Personal, 0, 10).unwrap().iter().map(|a| a.id).collect();
        assert_eq!(trash, vec![1]);
        assert_eq!(core.trash_count(Space::Personal).unwrap(), 1);
    }

    #[tokio::test]
    async fn delete_to_trash_leaves_db_unchanged_when_the_server_write_fails() {
        let mut server = mockito::Server::new_async().await;
        let _login = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"sid":"S"}}"#)
            .create_async()
            .await;
        let _albums = mock_album_list(
            &mut server,
            r#"{"success":true,"data":{"list":[{"id":500,"name":"Recently Deleted","item_count":0}]}}"#,
        );
        let _add = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=add_item".into()))
            .with_status(200)
            .with_body(r#"{"success":false,"error":{"code":400}}"#)
            .create_async()
            .await;

        let core = logged_in_core("delete-to-trash-fail", &server).await;
        seed_trash_album_id(&core, Space::Personal, 500);
        seed_asset(&core, Space::Personal, 1);

        let err = core.delete_to_trash(Space::Personal, vec![1]).await.unwrap_err();
        assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");

        // Fail closed: the local mirror must be completely unchanged.
        assert_eq!(core.asset_count(Space::Personal).unwrap(), 1, "a failed server write must not trash locally");
        assert_eq!(core.trash_count(Space::Personal).unwrap(), 0);
    }

    #[tokio::test]
    async fn restore_from_trash_returns_asset_to_library() {
        let mut server = mockito::Server::new_async().await;
        let _login = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"sid":"S"}}"#)
            .create_async()
            .await;
        let _albums = mock_album_list(
            &mut server,
            r#"{"success":true,"data":{"list":[{"id":500,"name":"Recently Deleted","item_count":1}]}}"#,
        );
        let _remove = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::AllOf(vec![
                mockito::Matcher::Regex("api=SYNO.Foto.Browse.NormalAlbum".into()),
                mockito::Matcher::Regex("method=delete_item".into()),
                mockito::Matcher::Regex("id=500".into()),
            ]))
            .with_status(200)
            .with_body(r#"{"success":true}"#)
            .create_async()
            .await;

        let core = logged_in_core("restore-from-trash", &server).await;
        seed_trash_album_id(&core, Space::Personal, 500);
        seed_trashed_asset(&core, Space::Personal, 1);
        assert_eq!(core.trash_count(Space::Personal).unwrap(), 1);
        assert_eq!(core.asset_count(Space::Personal).unwrap(), 0);

        core.restore_from_trash(Space::Personal, vec![1]).await.expect("restore ok");

        assert_eq!(core.trash_count(Space::Personal).unwrap(), 0);
        assert_eq!(core.asset_count(Space::Personal).unwrap(), 1, "restored asset returns to the library");
        assert!(core.fetch_trash(Space::Personal, 0, 10).unwrap().is_empty());
    }

    #[tokio::test]
    async fn permanently_delete_refuses_a_non_trashed_asset_with_zero_network_calls() {
        let mut server = mockito::Server::new_async().await;
        let _login = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"sid":"S"}}"#)
            .create_async()
            .await;
        // A trap: any delete verb reaching the NAS is a bug. Zero expected.
        let _trap = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=delete".into()))
            .expect(0)
            .with_status(200)
            .with_body(r#"{"success":true}"#)
            .create_async()
            .await;

        let core = logged_in_core("perm-delete-refused", &server).await;
        // Seeded as a LIVE (non-trashed) asset: it must never be permanently
        // deletable directly.
        seed_asset(&core, Space::Personal, 1);

        let err = core.permanently_delete(Space::Personal, vec![1]).await.unwrap_err();
        assert!(matches!(err, CoreError::WriteRefused), "got {err:?}");
        // The asset is untouched, and crucially the delete verb was never sent.
        assert_eq!(core.asset_count(Space::Personal).unwrap(), 1);
        _trap.assert_async().await;
    }

    #[tokio::test]
    async fn permanently_delete_removes_a_trashed_asset_on_server_success() {
        let mut server = mockito::Server::new_async().await;
        let _login = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"sid":"S"}}"#)
            .create_async()
            .await;
        let _delete = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::AllOf(vec![
                mockito::Matcher::Regex("api=SYNO.Foto.Browse.Item".into()),
                mockito::Matcher::Regex("method=delete".into()),
                mockito::Matcher::Regex("id=%5B1%5D".into()),
            ]))
            .with_status(200)
            .with_body(r#"{"success":true}"#)
            .expect(1)
            .create_async()
            .await;

        let core = logged_in_core("perm-delete-ok", &server).await;
        seed_trashed_asset(&core, Space::Personal, 1);
        assert_eq!(core.trash_count(Space::Personal).unwrap(), 1);

        core.permanently_delete(Space::Personal, vec![1]).await.expect("permanent delete ok");

        // The row is gone entirely, not merely un-flagged.
        assert_eq!(core.trash_count(Space::Personal).unwrap(), 0);
        assert_eq!(core.asset_count(Space::Personal).unwrap(), 0);
        assert!(core.fetch_trash(Space::Personal, 0, 10).unwrap().is_empty());
        _delete.assert_async().await;
    }

    #[tokio::test]
    async fn ensure_trash_album_creates_it_when_absent() {
        let mut server = mockito::Server::new_async().await;
        let _login = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"sid":"S"}}"#)
            .create_async()
            .await;
        let _albums = mock_album_list(&mut server, r#"{"success":true,"data":{"list":[]}}"#);
        let _create = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::AllOf(vec![
                mockito::Matcher::Regex("api=SYNO.Foto.Browse.NormalAlbum".into()),
                mockito::Matcher::Regex("method=create".into()),
            ]))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"album":{"id":777,"name":"Recently Deleted","item_count":0}}}"#)
            .expect(1)
            .create_async()
            .await;

        let core = logged_in_core("ensure-trash-create", &server).await;
        let album = core.ensure_trash_album(Space::Personal).await.expect("ensure ok");
        assert_eq!(album.id, 777);
        assert_eq!(album.name, "Recently Deleted");
        _create.assert_async().await;
    }

    #[tokio::test]
    async fn ensure_trash_album_reuses_the_persisted_id_and_does_not_create() {
        let mut server = mockito::Server::new_async().await;
        let _login = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"sid":"S"}}"#)
            .create_async()
            .await;
        let _albums = mock_album_list(
            &mut server,
            r#"{"success":true,"data":{"list":[{"id":500,"name":"Recently Deleted","item_count":3}]}}"#,
        );
        // If ensure_trash_album tries to create despite the stored id still
        // existing on the NAS, this trap (expect 0) fails the test.
        let _create_trap = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=create".into()))
            .expect(0)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"album":{"id":999,"name":"Recently Deleted","item_count":0}}}"#)
            .create_async()
            .await;

        let core = logged_in_core("ensure-trash-reuse", &server).await;
        seed_trash_album_id(&core, Space::Personal, 500);
        let album = core.ensure_trash_album(Space::Personal).await.expect("ensure ok");
        assert_eq!(album.id, 500, "must reuse the album whose id is stored, not create a second one");
        _create_trap.assert_async().await;
    }

    /// FIX A (findings 2+5): a user's own album that merely happens to be
    /// named "Recently Deleted" must NEVER be adopted as trash. With no stored
    /// id, ensure_trash_album must create its OWN album and persist that id,
    /// not hijack the same-named album (whose photos would otherwise become
    /// permanent-delete eligible).
    #[tokio::test]
    async fn ensure_trash_album_never_adopts_a_same_named_album_by_name() {
        let mut server = mockito::Server::new_async().await;
        let _login = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"sid":"S"}}"#)
            .create_async()
            .await;
        // A user-created album named exactly "Recently Deleted" (id 42) that
        // the app did NOT create.
        let _albums = mock_album_list(
            &mut server,
            r#"{"success":true,"data":{"list":[{"id":42,"name":"Recently Deleted","item_count":9}]}}"#,
        );
        let _create = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=create".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"album":{"id":777,"name":"Recently Deleted","item_count":0}}}"#)
            .expect(1)
            .create_async()
            .await;

        let core = logged_in_core("ensure-trash-no-adopt", &server).await;
        let album = core.ensure_trash_album(Space::Personal).await.expect("ensure ok");
        assert_eq!(album.id, 777, "must create its own album, not adopt the user's same-named album 42");
        assert_ne!(album.id, 42);
        // And the freshly created id must be persisted for next time.
        let stored = {
            let guard = core.store.lock().unwrap();
            guard.as_ref().unwrap().get_app_state(Space::Personal, super::TRASH_ALBUM_ID_KEY).unwrap()
        };
        assert_eq!(stored, Some("777".to_string()));
        _create.assert_async().await;
    }

    /// FIX A: when the stored id no longer exists on the NAS (the album was
    /// deleted elsewhere), ensure_trash_album must create a fresh one, persist
    /// the new id, and NOT keep serving the dead id.
    #[tokio::test]
    async fn ensure_trash_album_recreates_when_the_stored_id_is_stale() {
        let mut server = mockito::Server::new_async().await;
        let _login = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"sid":"S"}}"#)
            .create_async()
            .await;
        // The album list does NOT contain the stored id 500 (it was deleted);
        // only an unrelated album 42 remains.
        let _albums = mock_album_list(
            &mut server,
            r#"{"success":true,"data":{"list":[{"id":42,"name":"Holiday","item_count":9}]}}"#,
        );
        let _create = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=create".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"album":{"id":888,"name":"Recently Deleted","item_count":0}}}"#)
            .expect(1)
            .create_async()
            .await;

        let core = logged_in_core("ensure-trash-stale", &server).await;
        seed_trash_album_id(&core, Space::Personal, 500);
        let album = core.ensure_trash_album(Space::Personal).await.expect("ensure ok");
        assert_eq!(album.id, 888, "a stale stored id must be replaced by a freshly created album");
        let stored = {
            let guard = core.store.lock().unwrap();
            guard.as_ref().unwrap().get_app_state(Space::Personal, super::TRASH_ALBUM_ID_KEY).unwrap()
        };
        assert_eq!(stored, Some("888".to_string()), "the new id must be persisted, not the dead one");
        _create.assert_async().await;
    }

    #[tokio::test]
    async fn delete_to_trash_empty_list_is_a_noop_without_network() {
        let mut server = mockito::Server::new_async().await;
        let _login = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"sid":"S"}}"#)
            .create_async()
            .await;
        // No album list / add_item mocks: an empty request must not touch the
        // network at all.
        let core = logged_in_core("delete-to-trash-empty", &server).await;
        core.delete_to_trash(Space::Personal, vec![]).await.expect("empty delete is a no-op");
    }

    #[tokio::test]
    async fn delete_to_trash_without_login_returns_auth_error() {
        let core = core_at("delete-to-trash-no-login");
        let err = core.delete_to_trash(Space::Personal, vec![1]).await.unwrap_err();
        assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
    }

    #[test]
    fn fetch_trash_and_trash_count_are_local_reads() {
        let core = core_at("fetch-trash-local");
        assert_eq!(core.trash_count(Space::Personal).unwrap(), 0);
        assert!(core.fetch_trash(Space::Personal, 0, 10).unwrap().is_empty());
    }

    #[tokio::test]
    async fn reconcile_trash_flags_members_and_clears_non_members() {
        let mut server = mockito::Server::new_async().await;
        let _login = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"sid":"S"}}"#)
            .create_async()
            .await;
        let _albums = mock_album_list(
            &mut server,
            r#"{"success":true,"data":{"list":[{"id":500,"name":"Recently Deleted","item_count":1}]}}"#,
        );
        // The trash album currently contains only item 2 (item 1 was restored
        // on another client; item 2 was trashed on another client).
        let _members = server
            .mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Browse.Item".into()),
                mockito::Matcher::UrlEncoded("album_id".into(), "500".into()),
            ]))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[{"id":2,"filename":"b.jpg","type":"photo","additional":{"thumbnail":{"cache_key":"CK2","unit_id":6002}}}]}}"#)
            .create_async()
            .await;

        let core = logged_in_core("reconcile-trash", &server).await;
        seed_trash_album_id(&core, Space::Personal, 500);
        // Locally: item 1 is flagged trashed (stale, no longer a member),
        // item 2 is a live library asset (should become trashed).
        seed_trashed_asset(&core, Space::Personal, 1);
        seed_asset(&core, Space::Personal, 2);

        core.reconcile_trash(Space::Personal).await.expect("reconcile ok");

        // After reconcile: item 2 is trashed (it is a member), item 1 is
        // restored to the library (it is no longer a member).
        let trash: Vec<i64> = core.fetch_trash(Space::Personal, 0, 10).unwrap().iter().map(|a| a.id).collect();
        assert_eq!(trash, vec![2], "only the real member is trashed");
        let library: Vec<i64> = core.fetch_assets(Space::Personal, 0, 10).unwrap().iter().map(|a| a.id).collect();
        assert_eq!(library, vec![1], "the non-member is restored to the library");
    }

    /// FIX C (finding 3): a spurious empty (or truncated) member listing must
    /// NOT mass-clear the local trash. Here the album reports item_count 3 but
    /// the member fetch comes back empty (a network hiccup); reconcile must
    /// skip the clear step and leave the locally-trashed item hidden.
    #[tokio::test]
    async fn reconcile_trash_does_not_clear_on_a_spurious_empty_listing() {
        let mut server = mockito::Server::new_async().await;
        let _login = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"sid":"S"}}"#)
            .create_async()
            .await;
        // The album genuinely has 3 members per its item_count...
        let _albums = mock_album_list(
            &mut server,
            r#"{"success":true,"data":{"list":[{"id":500,"name":"Recently Deleted","item_count":3}]}}"#,
        );
        // ...but the member listing spuriously returns empty.
        let _members = server
            .mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Browse.Item".into()),
                mockito::Matcher::UrlEncoded("album_id".into(), "500".into()),
            ]))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[]}}"#)
            .create_async()
            .await;

        let core = logged_in_core("reconcile-spurious-empty", &server).await;
        seed_trash_album_id(&core, Space::Personal, 500);
        seed_trashed_asset(&core, Space::Personal, 1);
        assert_eq!(core.trash_count(Space::Personal).unwrap(), 1);

        core.reconcile_trash(Space::Personal).await.expect("reconcile ok");

        // The clear step must have been skipped (enumerated 0 != item_count 3),
        // so the locally-trashed item stays hidden rather than being un-hidden.
        assert_eq!(core.trash_count(Space::Personal).unwrap(), 1, "a short listing must not mass-clear trash");
        let trash: Vec<i64> = core.fetch_trash(Space::Personal, 0, 10).unwrap().iter().map(|a| a.id).collect();
        assert_eq!(trash, vec![1]);
    }

    /// FIX C: when there is no identifiable trash album (nothing stored, so
    /// the stored id is absent from the album list), reconcile must skip
    /// entirely and never clear local trash flags.
    #[tokio::test]
    async fn reconcile_trash_skips_when_no_trash_album_is_known() {
        let mut server = mockito::Server::new_async().await;
        let _login = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"sid":"S"}}"#)
            .create_async()
            .await;
        let _albums = mock_album_list(&mut server, r#"{"success":true,"data":{"list":[]}}"#);
        // If reconcile tried to enumerate members, this trap would be hit; it
        // must not, because there is no known trash album.
        let _members_trap = server
            .mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("album_id".into(), "500".into()))
            .expect(0)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[]}}"#)
            .create_async()
            .await;

        let core = logged_in_core("reconcile-no-album", &server).await;
        seed_trashed_asset(&core, Space::Personal, 1);

        core.reconcile_trash(Space::Personal).await.expect("reconcile is a safe no-op");
        assert_eq!(core.trash_count(Space::Personal).unwrap(), 1, "no known album must not clear trash");
        _members_trap.assert_async().await;
    }

    /// FIX B (finding 1): trash mutations serialize on `trash_lock`. Holding
    /// the lock blocks a concurrent `permanently_delete` BEFORE its guard
    /// check and any network call, so a restore can never slip in between the
    /// guard and the raw delete. Proven deterministically: while the test
    /// holds the lock, the spawned permanently_delete makes no progress (the
    /// item stays trashed and the delete verb is not sent); once released, it
    /// completes.
    #[tokio::test]
    async fn trash_mutations_serialize_on_the_trash_lock() {
        let mut server = mockito::Server::new_async().await;
        let _login = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"sid":"S"}}"#)
            .create_async()
            .await;
        let _delete = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=delete".into()))
            .with_status(200)
            .with_body(r#"{"success":true}"#)
            .create_async()
            .await;

        let core = logged_in_core("trash-serialize", &server).await;
        seed_trashed_asset(&core, Space::Personal, 1);

        // Hold the trash lock, then spawn permanently_delete; it must block on
        // the lock before touching the store guard or the network.
        let held = core.trash_lock.lock().await;
        let core2 = core.clone();
        let handle = tokio::spawn(async move { core2.permanently_delete(Space::Personal, vec![1]).await });

        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        assert!(!handle.is_finished(), "permanently_delete must block while the trash lock is held");
        assert_eq!(core.trash_count(Space::Personal).unwrap(), 1, "no mutation while the lock is held");

        // Release the lock; permanently_delete now proceeds and completes.
        drop(held);
        handle.await.unwrap().expect("permanently_delete completes after the lock is released");
        assert_eq!(core.trash_count(Space::Personal).unwrap(), 0);
        assert_eq!(core.asset_count(Space::Personal).unwrap(), 0);
    }
}
