//! Resumable, progress-tracked full crawl of a space.
//!
//! The crawl pages through a `PageSource` starting from the persisted cursor
//! (so an interrupted crawl resumes instead of restarting from zero), upserts
//! each page into the `Store`, and reports `CrawlProgress` as it goes. The
//! `initial_crawl_complete` barrier is only flipped once the crawl has
//! genuinely reached the end of the space; a partial or interrupted crawl
//! always leaves it false.
//!
//! Stop condition: `AssetPage` carries no `has_more` flag, so the loop cannot
//! rely on a single heuristic. A page is treated as the *last* page ("short
//! page") whenever it returns fewer items than the requested `limit`,
//! including zero items (an empty page). That alone is enough to stop the
//! loop safely even if the server's reported `total` is wrong in either
//! direction:
//! - If `total` undercounts the real item count, the server just keeps
//!   returning full pages past `offset >= total`; the loop keeps paging
//!   until it eventually receives a short page, so it never stops early and
//!   never loops forever waiting for `offset` to satisfy a `total` that will
//!   never be reached by full pages alone.
//! - If `total` overcounts the real item count, the short/empty page arrives
//!   before `offset` reaches `total`; the loop still stops on that page.
//! - Exact boundary (`total` is a multiple of `limit`): the last real page is
//!   full (`fetched == limit`), so the loop does one further request, which
//!   comes back empty, and that empty page is what stops it.
//!
//! The completion barrier is a separate, stricter condition than "stop the
//! loop": it only flips true when the loop stopped on a short page *and* the
//! cumulative fetched count has reached the last-known `expected_total`. A
//! short final page that lands short of `expected_total` (server undercounted
//! after all, or the crawl was cut off) stops the loop but leaves the barrier
//! down, so the UI keeps treating the library as partial.

use crate::PageSource;
use models::{CoreError, CrawlProgress, Space};
use persistence::Store;

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Sync-engine-internal progress abstraction. The FFI layer adapts its own
/// observer type onto this so sync-engine stays free of UniFFI concerns.
pub trait ProgressSink: Send + Sync {
    fn emit(&self, progress: CrawlProgress);
}

/// Drives a resumable crawl of one space against a `PageSource`, persisting
/// progress into a `Store` after every page.
pub struct Crawler<'a> {
    store: &'a Store,
    source: &'a dyn PageSource,
    page_limit: u32,
}

impl<'a> Crawler<'a> {
    pub fn new(store: &'a Store, source: &'a dyn PageSource, page_limit: u32) -> Self {
        Crawler { store, source, page_limit }
    }

    /// Runs the crawl for `space` to completion (or until interrupted by an
    /// error), reporting progress to `sink` after each page.
    ///
    /// If the space's barrier is already set, this is a no-op that reports
    /// the current progress and does not touch the `PageSource` at all
    /// (re-running a completed crawl must not re-fetch anything).
    ///
    /// On error mid-crawl, the cursor for every page fetched so far has
    /// already been persisted, so calling this again later resumes from the
    /// last successful page instead of starting over.
    pub async fn crawl_space(&self, space: Space, sink: &dyn ProgressSink) -> Result<CrawlProgress, CoreError> {
        let state = self.store.load_sync_state(space)?;
        if state.initial_crawl_complete {
            let progress = self.store.crawl_progress(space)?;
            sink.emit(progress.clone());
            return Ok(progress);
        }

        let limit = self.page_limit.max(1);
        let mut offset = state.last_offset;
        let mut expected_total;

        loop {
            let page = self.source.list_items(space, offset, limit).await?;
            expected_total = page.total;
            let fetched = page.assets.len() as u32;

            if fetched > 0 {
                self.store.upsert_assets(&page.assets)?;
            }
            if let Some(max_version) = page.assets.iter().filter_map(|a| a.server_version).max() {
                self.store.set_highest_version(space, max_version)?;
            }

            offset += fetched;
            self.store.save_cursor(space, offset, limit, expected_total)?;

            // A page shorter than requested (including empty) is the only
            // reliable end-of-space signal: it is correct regardless of
            // whether `expected_total` under- or over-counts the real total,
            // and it is what fires on the request past an exact multiple of
            // `limit`.
            let short_page = fetched < limit;

            if short_page {
                self.reconcile(space, offset, expected_total)?;

                let reached_expected_total = (offset as u64) >= expected_total;
                if reached_expected_total {
                    self.store.set_crawl_complete(space, true, now_secs())?;
                }

                let progress = self.store.crawl_progress(space)?;
                sink.emit(progress.clone());
                return Ok(progress);
            }

            let progress = self.store.crawl_progress(space)?;
            sink.emit(progress.clone());
        }
    }

    /// Compares the cursor's cumulative fetched count against the server's
    /// last-reported `expected_total` and records that a reconcile pass ran.
    /// A mismatch does not error the crawl (the barrier logic already keeps
    /// an undercount from being reported complete); it is surfaced via
    /// tracing so operators can see when the server's `total` disagreed with
    /// what was actually paged through.
    fn reconcile(&self, space: Space, fetched_count: u32, expected_total: u64) -> Result<(), CoreError> {
        if (fetched_count as u64) != expected_total {
            tracing::warn!(
                ?space,
                fetched_count,
                expected_total,
                "crawl finished with fetched count different from server-reported total"
            );
        }
        self.store.set_reconcile_at(space, now_secs())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{AssetPage, PageSource};
    use models::{Asset, CoreError, MediaKind, Space};
    use persistence::Store;
    use std::sync::Mutex;

    fn asset(id: i64, ver: i64) -> Asset {
        Asset {
            id, unit_id: id + 9000, cache_key: format!("ck{id}"), filename: format!("IMG_{id}.jpg"),
            media_kind: MediaKind::Photo, taken_at: Some(id * 10), added_at: Some(1),
            width: Some(100), height: Some(100), file_size: Some(1),
            space: Space::Personal, server_version: Some(ver),
        }
    }

    struct ScriptedSource {
        pages: Vec<AssetPage>,
        calls: Mutex<Vec<(u32, u32)>>,
    }
    #[async_trait::async_trait]
    impl PageSource for ScriptedSource {
        async fn list_items(&self, _space: Space, offset: u32, limit: u32) -> Result<AssetPage, CoreError> {
            self.calls.lock().unwrap().push((offset, limit));
            let idx = (offset / limit) as usize;
            Ok(self.pages.get(idx).cloned().unwrap_or(AssetPage { assets: vec![], total: self.pages_total() }))
        }
    }
    impl ScriptedSource {
        fn pages_total(&self) -> u64 { self.pages.first().map(|p| p.total).unwrap_or(0) }
    }

    /// A source that errors on a specific call index, used to simulate an
    /// interrupted crawl (network drop, app kill) partway through paging.
    struct FlakySource {
        pages: Vec<AssetPage>,
        fail_at_call: usize,
        calls: Mutex<usize>,
    }
    #[async_trait::async_trait]
    impl PageSource for FlakySource {
        async fn list_items(&self, _space: Space, offset: u32, limit: u32) -> Result<AssetPage, CoreError> {
            let mut calls = self.calls.lock().unwrap();
            let this_call = *calls;
            *calls += 1;
            if this_call == self.fail_at_call {
                return Err(CoreError::Network { message: "simulated drop".into() });
            }
            let idx = (offset / limit) as usize;
            Ok(self.pages.get(idx).cloned().unwrap_or(AssetPage { assets: vec![], total: 0 }))
        }
    }

    struct CountingSink { events: Mutex<Vec<CrawlProgress>> }
    impl ProgressSink for CountingSink {
        fn emit(&self, p: CrawlProgress) { self.events.lock().unwrap().push(p); }
    }

    #[tokio::test]
    async fn full_crawl_persists_all_and_sets_barrier() {
        let store = Store::open_in_memory().unwrap();
        let src = ScriptedSource {
            pages: vec![
                AssetPage { assets: vec![asset(1, 1), asset(2, 1)], total: 3 },
                AssetPage { assets: vec![asset(3, 1)], total: 3 },
            ],
            calls: Mutex::new(vec![]),
        };
        let sink = CountingSink { events: Mutex::new(vec![]) };
        let crawler = Crawler::new(&store, &src, 2);
        let final_p = crawler.crawl_space(Space::Personal, &sink).await.unwrap();
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 3);
        assert!(final_p.complete);
        assert_eq!(final_p.done, 3);
        assert_eq!(final_p.total, 3);
        let st = store.load_sync_state(Space::Personal).unwrap();
        assert!(st.initial_crawl_complete);
        assert_eq!(st.highest_seen_version, Some(1));
        let events = sink.events.lock().unwrap();
        assert!(events.len() >= 2);
        assert!(events.last().unwrap().complete);
    }

    #[tokio::test]
    async fn interrupted_crawl_resumes_from_cursor() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_assets(&[asset(1, 1), asset(2, 1)]).unwrap();
        store.save_cursor(Space::Personal, 2, 2, 3).unwrap();
        let src = ScriptedSource {
            pages: vec![
                AssetPage { assets: vec![asset(1, 1), asset(2, 1)], total: 3 },
                AssetPage { assets: vec![asset(3, 1)], total: 3 },
            ],
            calls: Mutex::new(vec![]),
        };
        let sink = CountingSink { events: Mutex::new(vec![]) };
        let crawler = Crawler::new(&store, &src, 2);
        crawler.crawl_space(Space::Personal, &sink).await.unwrap();
        let calls = src.calls.lock().unwrap();
        assert_eq!(calls.first().copied(), Some((2, 2)));
        assert!(!calls.contains(&(0, 2)));
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 3);
    }

    #[tokio::test]
    async fn completed_crawl_is_noop_on_recall() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_assets(&[asset(1, 1)]).unwrap();
        store.save_cursor(Space::Personal, 1, 2, 1).unwrap();
        store.set_crawl_complete(Space::Personal, true, 1).unwrap();
        let src = ScriptedSource { pages: vec![], calls: Mutex::new(vec![]) };
        let sink = CountingSink { events: Mutex::new(vec![]) };
        let crawler = Crawler::new(&store, &src, 2);
        let p = crawler.crawl_space(Space::Personal, &sink).await.unwrap();
        assert!(p.complete);
        assert!(src.calls.lock().unwrap().is_empty());
    }

    /// A crawl that dies partway through (simulated by an error from the
    /// source) must leave the barrier down and must have persisted the
    /// cursor for the pages that succeeded before the failure, so a later
    /// retry resumes instead of re-fetching from zero.
    #[tokio::test]
    async fn crawl_interrupted_by_error_leaves_barrier_false_and_resumable_cursor() {
        let store = Store::open_in_memory().unwrap();
        let src = FlakySource {
            pages: vec![
                AssetPage { assets: vec![asset(1, 1), asset(2, 1)], total: 5 },
                AssetPage { assets: vec![asset(3, 1), asset(4, 1)], total: 5 },
                AssetPage { assets: vec![asset(5, 1)], total: 5 },
            ],
            fail_at_call: 1, // fail on the second page request
            calls: Mutex::new(0),
        };
        let sink = CountingSink { events: Mutex::new(vec![]) };
        let crawler = Crawler::new(&store, &src, 2);

        let err = crawler.crawl_space(Space::Personal, &sink).await;
        assert!(err.is_err());

        // First page landed before the failure.
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 2);
        let st = store.load_sync_state(Space::Personal).unwrap();
        assert!(!st.initial_crawl_complete, "barrier must stay false on interrupted crawl");
        assert_eq!(st.last_offset, 2, "cursor must persist past the successful page");

        // Resume with a source that succeeds all the way through.
        let resume_src = ScriptedSource {
            pages: vec![
                AssetPage { assets: vec![asset(1, 1), asset(2, 1)], total: 5 },
                AssetPage { assets: vec![asset(3, 1), asset(4, 1)], total: 5 },
                AssetPage { assets: vec![asset(5, 1)], total: 5 },
            ],
            calls: Mutex::new(vec![]),
        };
        let resumed = Crawler::new(&store, &resume_src, 2);
        let final_p = resumed.crawl_space(Space::Personal, &sink).await.unwrap();

        let calls = resume_src.calls.lock().unwrap();
        assert_eq!(calls.first().copied(), Some((2, 2)), "resume must start from the saved cursor, not zero");
        assert!(!calls.contains(&(0, 2)), "resume must not re-fetch the already-persisted first page");

        assert_eq!(store.asset_count(Space::Personal).unwrap(), 5);
        assert!(final_p.complete);
        let st = store.load_sync_state(Space::Personal).unwrap();
        assert!(st.initial_crawl_complete, "barrier must flip true once the resumed crawl reaches the end");
    }

    /// A partial crawl (source runs dry before `expected_total` is reached
    /// and stays that way) must leave the barrier false even though the loop
    /// itself stopped cleanly on a short page.
    #[tokio::test]
    async fn partial_crawl_leaves_barrier_false() {
        let store = Store::open_in_memory().unwrap();
        // Total claims 10 items but the source only ever has 2, so the crawl
        // stops on a short (empty) second page well short of expected_total.
        let src = ScriptedSource {
            pages: vec![
                AssetPage { assets: vec![asset(1, 1), asset(2, 1)], total: 10 },
            ],
            calls: Mutex::new(vec![]),
        };
        let sink = CountingSink { events: Mutex::new(vec![]) };
        let crawler = Crawler::new(&store, &src, 2);
        let p = crawler.crawl_space(Space::Personal, &sink).await.unwrap();

        assert!(!p.complete, "must not claim complete when fetched count falls short of expected_total");
        let st = store.load_sync_state(Space::Personal).unwrap();
        assert!(!st.initial_crawl_complete);
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 2);
    }

    /// Exact-boundary case: `total` is precisely a multiple of `limit`, so
    /// the last real page is full and the loop must issue one more request
    /// (which comes back empty) before it can recognize completion.
    #[tokio::test]
    async fn exact_multiple_of_limit_stops_on_trailing_empty_page() {
        let store = Store::open_in_memory().unwrap();
        let src = ScriptedSource {
            pages: vec![
                AssetPage { assets: vec![asset(1, 1), asset(2, 1)], total: 4 },
                AssetPage { assets: vec![asset(3, 1), asset(4, 1)], total: 4 },
                // idx 2 (offset 4) falls through to the default empty page.
            ],
            calls: Mutex::new(vec![]),
        };
        let sink = CountingSink { events: Mutex::new(vec![]) };
        let crawler = Crawler::new(&store, &src, 2);
        let p = crawler.crawl_space(Space::Personal, &sink).await.unwrap();

        assert!(p.complete);
        assert_eq!(p.done, 4);
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 4);
        let calls = src.calls.lock().unwrap();
        assert_eq!(calls.as_slice(), &[(0, 2), (2, 2), (4, 2)], "must issue the trailing request past the exact boundary");
    }

    /// Short-but-nonempty final page: the last page has 1 item where the
    /// limit is 2, and cumulative fetched matches `expected_total` exactly,
    /// so the crawl must stop there (no trailing empty-page request) and set
    /// the barrier.
    #[tokio::test]
    async fn short_nonempty_final_page_completes_without_extra_request() {
        let store = Store::open_in_memory().unwrap();
        let src = ScriptedSource {
            pages: vec![
                AssetPage { assets: vec![asset(1, 1), asset(2, 1)], total: 3 },
                AssetPage { assets: vec![asset(3, 1)], total: 3 },
            ],
            calls: Mutex::new(vec![]),
        };
        let sink = CountingSink { events: Mutex::new(vec![]) };
        let crawler = Crawler::new(&store, &src, 2);
        let p = crawler.crawl_space(Space::Personal, &sink).await.unwrap();

        assert!(p.complete);
        assert_eq!(p.done, 3);
        let calls = src.calls.lock().unwrap();
        assert_eq!(calls.as_slice(), &[(0, 2), (2, 2)], "must not fetch a third page once the short page is seen");
    }

    /// Undercounted total: the server reports a smaller `total` than the
    /// real item count, so full pages keep arriving past `offset >= total`.
    /// The loop must keep going (not stop just because offset caught up to
    /// the wrong total) and only stop once an actual short page arrives.
    #[tokio::test]
    async fn undercounted_total_keeps_paging_past_reported_total() {
        let store = Store::open_in_memory().unwrap();
        let src = ScriptedSource {
            pages: vec![
                // Reports total=2 but there are actually 5 items across three
                // full-looking pages plus a short trailing page.
                AssetPage { assets: vec![asset(1, 1), asset(2, 1)], total: 2 },
                AssetPage { assets: vec![asset(3, 1), asset(4, 1)], total: 2 },
                AssetPage { assets: vec![asset(5, 1)], total: 2 },
            ],
            calls: Mutex::new(vec![]),
        };
        let sink = CountingSink { events: Mutex::new(vec![]) };
        let crawler = Crawler::new(&store, &src, 2);
        let p = crawler.crawl_space(Space::Personal, &sink).await.unwrap();

        assert_eq!(store.asset_count(Space::Personal).unwrap(), 5, "must not stop early just because offset passed the wrong total");
        assert_eq!(p.done, 5);
        // expected_total was corrected by the final page's report; barrier
        // reflects the corrected total, not the stale early value.
        assert!(p.complete);
        let calls = src.calls.lock().unwrap();
        assert_eq!(calls.len(), 3, "must keep paging past the undercounted total until a short page arrives");
    }

    #[tokio::test]
    async fn empty_space_completes_immediately() {
        let store = Store::open_in_memory().unwrap();
        let src = ScriptedSource {
            pages: vec![AssetPage { assets: vec![], total: 0 }],
            calls: Mutex::new(vec![]),
        };
        let sink = CountingSink { events: Mutex::new(vec![]) };
        let crawler = Crawler::new(&store, &src, 2);
        let p = crawler.crawl_space(Space::Personal, &sink).await.unwrap();

        assert!(p.complete);
        assert_eq!(p.done, 0);
        assert_eq!(p.total, 0);
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 0);
    }
}
