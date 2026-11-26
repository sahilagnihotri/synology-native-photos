//! Delta reconciliation: keeps the local mirror in sync with the server by
//! keying strictly on server identity (`server_id`) and the server's own
//! version watermark (`server_version`), never on wall-clock time.
//!
//! Why not a timestamp delta: comparing `taken_at`/`added_at` against a
//! "last synced at" wall-clock cutoff is the classic source of a permanent,
//! silent hole. Clock skew between the NAS and the Mac, or two items landing
//! in the same watermark second, can put an item on the wrong side of the
//! cutoff forever; nothing about a later sync would ever notice, because the
//! item's timestamp never changes. Keying on `(server_id, server_version)`
//! avoids this class of bug entirely: whether an item is new or changed is
//! decided by comparing identity/version fields the server itself controls,
//! not by comparing against any clock.
//!
//! Algorithm:
//! - NEW: a server id absent from the local version index is inserted.
//! - CHANGED: a server id present locally whose `server_version` differs
//!   from the server's is upserted (overwrites the local row).
//! - UNCHANGED: a server id present locally with an identical
//!   `server_version` is left alone (no write, no re-decode).
//! - DELETED (mirror only): reconcile pages through the *entire* current
//!   server listing for the space, building the full set of ids the server
//!   reports right now. Once paging reaches the end, any local row whose id
//!   is absent from that set no longer exists on the server, so the stale
//!   local row is removed to keep the mirror honest. This never issues a
//!   write to the NAS; it only deletes the local copy of a fact the server
//!   has already changed.

use crate::PageSource;
use models::{CoreError, CrawlProgress, Space};
use persistence::Store;
use std::collections::{HashMap, HashSet};

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Share of a space's local rows (in percent) that one reconcile may remove
/// without confirmation. Real server side deletions arrive a few at a time
/// (a cleanup session on the phone or the web), while a listing that ends
/// early (a re-index, a briefly unavailable volume, a session race) drops a
/// large slice or everything. Twenty percent sits well above routine
/// deletions and well below the truncation cases. A bigger drop is applied
/// only when the next reconcile sees the identical listing.
const MAX_UNCONFIRMED_DELETE_PERCENT: usize = 20;

/// Below this many local rows the share rule is not applied: in a tiny space
/// a single deletion is already a large share, and the cost of a wrong sweep
/// is small. An empty listing is still refused at any size.
const MIN_GUARDED_LOCAL_ROWS: usize = 100;

/// `app_state` key holding the fingerprint of the last refused listing, so
/// an identical listing on the next reconcile counts as confirmation.
const PENDING_SWEEP_KEY: &str = "reconcile_pending_sweep";

/// Order independent, stable fingerprint of a sorted id list (FNV-1a over
/// the ids plus the count). Stable across builds, unlike `DefaultHasher`.
fn listing_fingerprint(sorted_ids: &[i64]) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for id in sorted_ids {
        for b in id.to_le_bytes() {
            h ^= u64::from(b);
            h = h.wrapping_mul(0x0100_0000_01b3);
        }
    }
    format!("{}:{h:016x}", sorted_ids.len())
}

pub struct DeltaReconciler<'a> {
    store: &'a Store,
    source: &'a dyn PageSource,
    page_limit: u32,
}

impl<'a> DeltaReconciler<'a> {
    pub fn new(store: &'a Store, source: &'a dyn PageSource, page_limit: u32) -> Self {
        DeltaReconciler {
            store,
            source,
            page_limit,
        }
    }

    /// Reconciles local state against the server for `space`.
    ///
    /// The only inputs to the NEW/CHANGED/UNCHANGED decision are `server_id`
    /// and `server_version`; no timestamp field is ever read for this
    /// purpose, so a clock-skewed or backdated `taken_at` cannot hide an item
    /// from the reconcile pass. Deletion is detected by diffing the full set
    /// of server ids seen while paging against the full set of local ids;
    /// this module only ever removes local rows and never sends a write or
    /// delete request to the NAS.
    pub async fn reconcile(&self, space: Space) -> Result<CrawlProgress, CoreError> {
        let local = self.store.fetch_assets(space, 0, u32::MAX)?;
        let mut local_versions: HashMap<i64, Option<i64>> = HashMap::with_capacity(local.len());
        for a in &local {
            local_versions.insert(a.id, a.server_version);
        }

        let limit = self.page_limit.max(1);
        let mut offset: u32 = 0;
        let mut seen_ids: HashSet<i64> = HashSet::with_capacity(local.len());

        loop {
            let page = self.source.list_items(space, offset, limit).await?;
            let fetched = page.assets.len() as u32;

            for a in &page.assets {
                seen_ids.insert(a.id);
            }

            // Keyed strictly on (server_id, server_version): a row with no
            // local entry is NEW, a row whose stored version differs is
            // CHANGED, and anything else is UNCHANGED and skipped. Nothing
            // here consults taken_at/added_at.
            let to_write: Vec<_> = page
                .assets
                .iter()
                .filter(|a| match local_versions.get(&a.id) {
                    None => true,
                    Some(stored) => *stored != a.server_version,
                })
                .cloned()
                .collect();

            if !to_write.is_empty() {
                self.store.upsert_assets(&to_write)?;
                for a in &to_write {
                    local_versions.insert(a.id, a.server_version);
                }
            }

            if let Some(v) = page.assets.iter().filter_map(|a| a.server_version).max() {
                self.store.set_highest_version(space, v)?;
            }

            offset += fetched;
            if fetched < limit {
                break;
            }
        }

        // Deletion mirror: the loop above has now seen every id the server
        // currently reports for this space (it only stops on a short page).
        // Any local row whose id never showed up is gone server-side, so the
        // stale local copy is dropped to keep the mirror honest. This is a
        // local-only DELETE against our own SQLite file. No NAS call is made
        // here or anywhere else in this module.
        //
        // Before sweeping, the listing has to look plausible: see
        // `sweep_is_plausible`. A refused sweep keeps every local row (the
        // upserts above still stand), leaves `reconcile_at` unset and
        // returns an error so the caller does not report a clean sync.
        let local_count = local_versions.len();
        let stale = local_versions
            .keys()
            .filter(|id| !seen_ids.contains(id))
            .count();
        let mut keep_ids: Vec<i64> = seen_ids.into_iter().collect();
        keep_ids.sort_unstable();
        if stale > 0 && !self.sweep_is_plausible(space, &keep_ids, stale, local_count)? {
            let message = if keep_ids.is_empty() {
                format!(
                    "The NAS listed no items, so none of the {local_count} local items were removed."
                )
            } else {
                format!(
                    "The NAS listing would remove {stale} of {local_count} local items, so none \
                     were removed. Refresh again to confirm the change."
                )
            };
            return Err(CoreError::UnexpectedResponse { message });
        }
        self.store.set_app_state(space, PENDING_SWEEP_KEY, "")?;
        self.store.delete_assets_not_in(space, &keep_ids)?;

        self.store.set_reconcile_at(space, now_secs())?;
        self.store.crawl_progress(space)
    }

    /// Decides whether removing `stale` of `local_count` local rows is safe.
    ///
    /// - An empty listing for a populated space is never applied: a
    ///   successful but empty answer is far likelier to be a server hiccup
    ///   than a library emptied on purpose.
    /// - In a space of at least `MIN_GUARDED_LOCAL_ROWS`, removing more than
    ///   `MAX_UNCONFIRMED_DELETE_PERCENT` percent is applied only when the
    ///   previous refused listing had the same fingerprint, so one glitch
    ///   can never empty the grid but a real mass deletion converges on the
    ///   second refresh.
    ///
    /// A refusal records the listing's fingerprint for the next reconcile.
    fn sweep_is_plausible(
        &self,
        space: Space,
        sorted_keep_ids: &[i64],
        stale: usize,
        local_count: usize,
    ) -> Result<bool, CoreError> {
        if sorted_keep_ids.is_empty() {
            return Ok(false);
        }
        let large_drop = local_count >= MIN_GUARDED_LOCAL_ROWS
            && stale * 100 > local_count * MAX_UNCONFIRMED_DELETE_PERCENT;
        if !large_drop {
            return Ok(true);
        }
        let fingerprint = listing_fingerprint(sorted_keep_ids);
        let pending = self.store.get_app_state(space, PENDING_SWEEP_KEY)?;
        if pending.as_deref() == Some(fingerprint.as_str()) {
            return Ok(true);
        }
        self.store
            .set_app_state(space, PENDING_SWEEP_KEY, &fingerprint)?;
        Ok(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{AssetPage, PageSource};
    use models::{Asset, CoreError, MediaKind, Space};
    use persistence::Store;

    fn asset_v(id: i64, ver: i64, taken: Option<i64>) -> Asset {
        Asset {
            id,
            unit_id: id + 9000,
            cache_key: format!("ck{id}-v{ver}"),
            filename: format!("IMG_{id}.jpg"),
            media_kind: MediaKind::Photo,
            taken_at: taken,
            added_at: Some(1),
            width: Some(100),
            height: Some(100),
            file_size: Some(1),
            space: Space::Personal,
            server_version: Some(ver),
            ..Default::default()
        }
    }

    struct ScriptedSource {
        pages: Vec<AssetPage>,
    }
    #[async_trait::async_trait]
    impl PageSource for ScriptedSource {
        async fn list_items(
            &self,
            _space: Space,
            offset: u32,
            limit: u32,
        ) -> Result<AssetPage, CoreError> {
            let idx = (offset / limit) as usize;
            Ok(self.pages.get(idx).cloned().unwrap_or(AssetPage {
                assets: vec![],
                total: self.total(),
            }))
        }
    }
    impl ScriptedSource {
        fn total(&self) -> u64 {
            self.pages.first().map(|p| p.total).unwrap_or(0)
        }
    }

    #[tokio::test]
    async fn changed_version_updates_row() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_assets(&[asset_v(1, 1, Some(100))]).unwrap();
        let src = ScriptedSource {
            pages: vec![AssetPage {
                assets: vec![asset_v(1, 2, Some(100))],
                total: 1,
            }],
        };
        let rec = DeltaReconciler::new(&store, &src, 100);
        rec.reconcile(Space::Personal).await.unwrap();
        let local = store.fetch_assets(Space::Personal, 0, 10).unwrap();
        assert_eq!(local.len(), 1);
        assert_eq!(local[0].server_version, Some(2));
        assert_eq!(local[0].cache_key, "ck1-v2");
        assert_eq!(
            store
                .load_sync_state(Space::Personal)
                .unwrap()
                .highest_seen_version,
            Some(2)
        );
    }

    #[tokio::test]
    async fn new_id_is_added() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_assets(&[asset_v(1, 1, Some(100))]).unwrap();
        let src = ScriptedSource {
            pages: vec![AssetPage {
                assets: vec![asset_v(1, 1, Some(100)), asset_v(2, 1, Some(200))],
                total: 2,
            }],
        };
        let rec = DeltaReconciler::new(&store, &src, 100);
        rec.reconcile(Space::Personal).await.unwrap();
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 2);
    }

    /// The whole point of keying on server id/version rather than wall-clock
    /// time: construct a scenario a timestamp-based delta would have missed.
    /// The local row's `taken_at` is 9_999 and the "last reconciled at"
    /// clock reads 10_000; a naive delta ("fetch anything with taken_at >
    /// last_reconcile_at") would never even ask the server about item 2,
    /// because item 2's `taken_at` (5_000) is *older* than the watermark,
    /// even though it is a brand-new server id the reconciler has never seen.
    /// Because this reconciler never looks at taken_at to decide what to
    /// fetch or import (it pages the whole listing and compares ids/versions),
    /// the backdated new item is still caught.
    #[tokio::test]
    async fn clock_skew_does_not_create_a_hole() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_assets(&[asset_v(1, 1, Some(9_999))]).unwrap();
        store.set_reconcile_at(Space::Personal, 10_000).unwrap();
        let src = ScriptedSource {
            pages: vec![AssetPage {
                assets: vec![asset_v(1, 1, Some(9_999)), asset_v(2, 1, Some(5_000))],
                total: 2,
            }],
        };
        let rec = DeltaReconciler::new(&store, &src, 100);
        rec.reconcile(Space::Personal).await.unwrap();
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 2);
        let ids: Vec<i64> = store
            .fetch_assets(Space::Personal, 0, 10)
            .unwrap()
            .iter()
            .map(|a| a.id)
            .collect();
        assert!(ids.contains(&2), "backdated new item was dropped (a hole)");
    }

    #[tokio::test]
    async fn unchanged_version_is_left_alone() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_assets(&[asset_v(1, 1, Some(100))]).unwrap();
        let mut same = asset_v(1, 1, Some(100));
        same.cache_key = "server-sent-but-same-version".into();
        let src = ScriptedSource {
            pages: vec![AssetPage {
                assets: vec![same],
                total: 1,
            }],
        };
        let rec = DeltaReconciler::new(&store, &src, 100);
        rec.reconcile(Space::Personal).await.unwrap();
        let local = store.fetch_assets(Space::Personal, 0, 10).unwrap();
        assert_eq!(local[0].cache_key, "ck1-v1");
    }

    /// An id the reconciler's own full-listing pass never sees is gone
    /// server-side; the stale local row must be removed so the mirror
    /// matches the server, and the watermark/version comparison alone would
    /// never do this (deletion has no "changed version" to detect).
    #[tokio::test]
    async fn deleted_on_server_asset_is_removed_locally() {
        let store = Store::open_in_memory().unwrap();
        store
            .upsert_assets(&[asset_v(1, 1, Some(100)), asset_v(2, 1, Some(200))])
            .unwrap();
        // Server now only reports id 1; id 2 was deleted server-side.
        let src = ScriptedSource {
            pages: vec![AssetPage {
                assets: vec![asset_v(1, 1, Some(100))],
                total: 1,
            }],
        };
        let rec = DeltaReconciler::new(&store, &src, 100);
        rec.reconcile(Space::Personal).await.unwrap();
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 1);
        let ids: Vec<i64> = store
            .fetch_assets(Space::Personal, 0, 10)
            .unwrap()
            .iter()
            .map(|a| a.id)
            .collect();
        assert_eq!(ids, vec![1]);
        assert!(
            !ids.contains(&2),
            "stale row for a server-deleted asset was not removed"
        );
    }

    /// Deletion mirroring must respect space isolation: reconciling Personal
    /// must never touch Shared rows, even ones the Personal source never
    /// mentions.
    #[tokio::test]
    async fn deletion_mirror_does_not_cross_spaces() {
        let store = Store::open_in_memory().unwrap();
        let mut shared_asset = asset_v(9, 1, Some(900));
        shared_asset.space = Space::Shared;
        store
            .upsert_assets(&[asset_v(1, 1, Some(100)), shared_asset])
            .unwrap();
        let src = ScriptedSource {
            pages: vec![AssetPage {
                assets: vec![asset_v(1, 1, Some(100))],
                total: 1,
            }],
        };
        let rec = DeltaReconciler::new(&store, &src, 100);
        rec.reconcile(Space::Personal).await.unwrap();
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 1);
        assert_eq!(
            store.asset_count(Space::Shared).unwrap(),
            1,
            "reconciling Personal must not sweep Shared rows"
        );
    }

    /// Serves a fixed listing in `offset`/`limit` windows, the way the real
    /// list call pages, so tests can feed listings of any size.
    struct SliceSource {
        items: Vec<Asset>,
    }
    #[async_trait::async_trait]
    impl PageSource for SliceSource {
        async fn list_items(
            &self,
            _space: Space,
            offset: u32,
            limit: u32,
        ) -> Result<AssetPage, CoreError> {
            let start = (offset as usize).min(self.items.len());
            let end = (start + limit as usize).min(self.items.len());
            Ok(AssetPage {
                assets: self.items[start..end].to_vec(),
                total: self.items.len() as u64,
            })
        }
    }

    fn seed(store: &Store, ids: impl Iterator<Item = i64>) {
        let rows: Vec<Asset> = ids.map(|id| asset_v(id, 1, Some(id))).collect();
        store.upsert_assets(&rows).unwrap();
    }

    fn listing(ids: impl Iterator<Item = i64>) -> SliceSource {
        SliceSource {
            items: ids.map(|id| asset_v(id, 1, Some(id))).collect(),
        }
    }

    /// R2-1 at the sync level: a 40,000 item library reconciles, the one
    /// server side deletion is mirrored and the one new item lands.
    #[tokio::test]
    async fn large_library_reconciles_past_the_sql_variable_limit() {
        let store = Store::open_in_memory().unwrap();
        seed(&store, 1..=40_000);
        let src = listing((2..=40_001).rev());
        let rec = DeltaReconciler::new(&store, &src, 200);
        rec.reconcile(Space::Personal).await.unwrap();
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 40_000);
        let ids: HashSet<i64> = store
            .fetch_assets(Space::Personal, 0, u32::MAX)
            .unwrap()
            .iter()
            .map(|a| a.id)
            .collect();
        assert!(!ids.contains(&1));
        assert!(ids.contains(&40_001));
    }

    /// A successful but empty listing for a populated space must never be
    /// applied as deletions, not even when it repeats, and the reconcile
    /// must not report success.
    #[tokio::test]
    async fn empty_listing_keeps_every_local_row() {
        let store = Store::open_in_memory().unwrap();
        seed(&store, 1..=500);
        let src = listing(std::iter::empty());
        let rec = DeltaReconciler::new(&store, &src, 200);
        for _ in 0..3 {
            let result = rec.reconcile(Space::Personal).await;
            assert!(
                matches!(result, Err(CoreError::UnexpectedResponse { .. })),
                "empty listing must be refused, got {result:?}"
            );
            assert_eq!(store.asset_count(Space::Personal).unwrap(), 500);
        }
        assert!(store
            .load_sync_state(Space::Personal)
            .unwrap()
            .last_reconcile_at
            .is_none());
    }

    /// A small, plausible server side deletion is mirrored straight away.
    #[tokio::test]
    async fn small_legitimate_deletion_is_applied() {
        let store = Store::open_in_memory().unwrap();
        seed(&store, 1..=500);
        let src = listing(11..=500);
        let rec = DeltaReconciler::new(&store, &src, 200);
        rec.reconcile(Space::Personal).await.unwrap();
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 490);
    }

    /// A listing that would remove more than the allowed share of a
    /// non-trivial space is refused the first time (new rows still land),
    /// and applied only when the next reconcile sees the identical listing.
    #[tokio::test]
    async fn listing_over_the_threshold_is_refused_until_repeated() {
        let store = Store::open_in_memory().unwrap();
        seed(&store, 1..=500);
        let src = listing(301..=501);
        let rec = DeltaReconciler::new(&store, &src, 200);

        let first = rec.reconcile(Space::Personal).await;
        assert!(
            matches!(first, Err(CoreError::UnexpectedResponse { .. })),
            "first sight of a 60 percent drop must be refused, got {first:?}"
        );
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 501);

        rec.reconcile(Space::Personal).await.unwrap();
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 201);
    }

    /// The confirmation must be the SAME listing: a different over-threshold
    /// listing on the next reconcile is refused again.
    #[tokio::test]
    async fn a_different_short_listing_does_not_confirm_the_first() {
        let store = Store::open_in_memory().unwrap();
        seed(&store, 1..=500);
        let first = listing(301..=500);
        let second = listing(1..=150);
        assert!(DeltaReconciler::new(&store, &first, 200)
            .reconcile(Space::Personal)
            .await
            .is_err());
        let result = DeltaReconciler::new(&store, &second, 200)
            .reconcile(Space::Personal)
            .await;
        assert!(
            matches!(result, Err(CoreError::UnexpectedResponse { .. })),
            "a different short listing must not count as confirmation, got {result:?}"
        );
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 500);
    }

    #[tokio::test]
    async fn watermark_advances_and_persists_across_pages() {
        let store = Store::open_in_memory().unwrap();
        let src = ScriptedSource {
            pages: vec![
                AssetPage {
                    assets: vec![asset_v(1, 3, Some(100)), asset_v(2, 5, Some(200))],
                    total: 3,
                },
                AssetPage {
                    assets: vec![asset_v(3, 4, Some(300))],
                    total: 3,
                },
            ],
        };
        let rec = DeltaReconciler::new(&store, &src, 2);
        rec.reconcile(Space::Personal).await.unwrap();
        assert_eq!(
            store
                .load_sync_state(Space::Personal)
                .unwrap()
                .highest_seen_version,
            Some(5)
        );
        assert!(store
            .load_sync_state(Space::Personal)
            .unwrap()
            .last_reconcile_at
            .is_some());
    }
}
