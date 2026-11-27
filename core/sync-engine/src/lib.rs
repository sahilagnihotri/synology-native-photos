//! Resumable progress-tracked crawl and delta reconciliation by server id/version.

use models::{Asset, CoreError, Space};

pub mod crawl;
pub mod delta;

/// One page of items from the server, plus the server-reported total for the space.
#[derive(Clone, Debug)]
pub struct AssetPage {
    pub assets: Vec<Asset>,
    pub total: u64,
}

/// One page as the crawl and the reconcile page through it: the decoded
/// assets plus what the server really returned. A server item that exists
/// but cannot be decoded yet (for example one still waiting for its
/// thumbnail, so it has no `cache_key`) is counted in `raw_count` and named
/// in `skipped_ids` instead of failing the page or shortening it.
#[derive(Clone, Debug)]
pub struct ListedPage {
    pub assets: Vec<Asset>,
    pub total: u64,
    /// Raw number of elements the server returned, decodable or not. The
    /// next offset is `offset + raw_count`, and a page is the last one only
    /// when `raw_count` is below the requested limit.
    pub raw_count: u32,
    /// Ids the server listed that could not be decoded. They are present on
    /// the server, so a reconcile must never treat them as deleted.
    pub skipped_ids: Vec<i64>,
}

/// Detects a server that ignores `offset`. A page is a repeat when it has the
/// same non-empty list of ids (decoded and skipped) as the page before it:
/// two adjacent windows of one listing never share ids, so a repeat means the
/// same items came back for a new offset and paging would never end.
#[derive(Default)]
pub(crate) struct PageGuard {
    previous: Option<Vec<i64>>,
}

impl PageGuard {
    /// Records `page` and fails if it repeats the previous page.
    pub(crate) fn check(&mut self, offset: u32, page: &ListedPage) -> Result<(), CoreError> {
        let mut ids: Vec<i64> = page.assets.iter().map(|a| a.id).collect();
        ids.extend(page.skipped_ids.iter().copied());
        if !ids.is_empty() && self.previous.as_ref() == Some(&ids) {
            return Err(CoreError::UnexpectedResponse {
                message: format!(
                    "the server returned the same page again at offset {offset}; it appears to ignore offset"
                ),
            });
        }
        self.previous = Some(ids);
        Ok(())
    }
}

/// Abstraction over the network list call so sync logic is testable without HTTP.
/// Group A's facade implements this over synology-api; sync-engine only knows the trait.
#[allow(clippy::double_must_use)] // async_trait adds must_use to the boxed future; not ours
#[async_trait::async_trait]
pub trait PageSource: Send + Sync {
    async fn list_items(
        &self,
        space: Space,
        offset: u32,
        limit: u32,
    ) -> Result<AssetPage, CoreError>;

    /// The page the crawl and the reconcile actually use. The default treats
    /// every listed item as decoded, which is right for a source that never
    /// skips; a source that can skip undecodable items overrides it.
    async fn list_page(
        &self,
        space: Space,
        offset: u32,
        limit: u32,
    ) -> Result<ListedPage, CoreError> {
        let page = self.list_items(space, offset, limit).await?;
        Ok(ListedPage {
            raw_count: page.assets.len() as u32,
            skipped_ids: Vec::new(),
            assets: page.assets,
            total: page.total,
        })
    }
}

/// In-memory page source shared by the crawl and reconcile tests: a fixed
/// listing paged by `offset`/`limit` in which some items cannot be decoded.
#[cfg(test)]
pub(crate) mod test_support {
    use super::*;
    use std::collections::HashSet;
    use std::sync::Mutex;

    pub(crate) struct SkippingSource {
        pub items: Vec<Asset>,
        /// Ids that are listed but do not decode yet (no cache_key).
        pub undecodable: Mutex<HashSet<i64>>,
        pub calls: Mutex<Vec<u32>>,
    }

    impl SkippingSource {
        pub(crate) fn new(items: Vec<Asset>, undecodable: &[i64]) -> Self {
            SkippingSource {
                items,
                undecodable: Mutex::new(undecodable.iter().copied().collect()),
                calls: Mutex::new(vec![]),
            }
        }

        fn window(&self, offset: u32, limit: u32) -> &[Asset] {
            let start = (offset as usize).min(self.items.len());
            let end = (start + limit as usize).min(self.items.len());
            &self.items[start..end]
        }
    }

    #[async_trait::async_trait]
    impl PageSource for SkippingSource {
        /// Only the decoded items, the way a source without raw counts
        /// would report them.
        async fn list_items(
            &self,
            _space: Space,
            offset: u32,
            limit: u32,
        ) -> Result<AssetPage, CoreError> {
            self.calls.lock().unwrap().push(offset);
            let bad = self.undecodable.lock().unwrap();
            Ok(AssetPage {
                assets: self
                    .window(offset, limit)
                    .iter()
                    .filter(|a| !bad.contains(&a.id))
                    .cloned()
                    .collect(),
                total: self.items.len() as u64,
            })
        }

        async fn list_page(
            &self,
            _space: Space,
            offset: u32,
            limit: u32,
        ) -> Result<ListedPage, CoreError> {
            self.calls.lock().unwrap().push(offset);
            let bad = self.undecodable.lock().unwrap();
            let window = self.window(offset, limit);
            Ok(ListedPage {
                assets: window
                    .iter()
                    .filter(|a| !bad.contains(&a.id))
                    .cloned()
                    .collect(),
                total: self.items.len() as u64,
                raw_count: window.len() as u32,
                skipped_ids: window
                    .iter()
                    .filter(|a| bad.contains(&a.id))
                    .map(|a| a.id)
                    .collect(),
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use models::{Asset, MediaKind, Space};
    use std::sync::Mutex;

    fn asset(id: i64, ver: i64) -> Asset {
        Asset {
            id,
            unit_id: id + 9000,
            cache_key: format!("ck{id}"),
            filename: format!("IMG_{id}.jpg"),
            media_kind: MediaKind::Photo,
            taken_at: Some(id * 10),
            added_at: Some(1),
            width: Some(100),
            height: Some(100),
            file_size: Some(1),
            space: Space::Personal,
            server_version: Some(ver),
            ..Default::default()
        }
    }

    pub struct FakeSource {
        pub pages: Vec<AssetPage>,
        pub calls: Mutex<Vec<(u32, u32)>>,
    }

    #[async_trait::async_trait]
    impl PageSource for FakeSource {
        async fn list_items(
            &self,
            _space: Space,
            offset: u32,
            limit: u32,
        ) -> Result<AssetPage, CoreError> {
            self.calls.lock().unwrap().push((offset, limit));
            let idx = (offset / limit) as usize;
            Ok(self.pages.get(idx).cloned().unwrap_or(AssetPage {
                assets: vec![],
                total: 0,
            }))
        }
    }

    #[tokio::test]
    async fn fake_source_returns_pages_in_order() {
        let src = FakeSource {
            pages: vec![
                AssetPage {
                    assets: vec![asset(1, 1), asset(2, 1)],
                    total: 3,
                },
                AssetPage {
                    assets: vec![asset(3, 1)],
                    total: 3,
                },
            ],
            calls: Mutex::new(vec![]),
        };
        let p0 = src.list_items(Space::Personal, 0, 2).await.unwrap();
        assert_eq!(p0.assets.len(), 2);
        assert_eq!(p0.total, 3);
        let p1 = src.list_items(Space::Personal, 2, 2).await.unwrap();
        assert_eq!(p1.assets.len(), 1);
        assert_eq!(src.calls.lock().unwrap().as_slice(), &[(0, 2), (2, 2)]);
    }
}
