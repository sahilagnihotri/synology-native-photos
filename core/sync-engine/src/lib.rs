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

/// Abstraction over the network list call so sync logic is testable without HTTP.
/// Group A's facade implements this over synology-api; sync-engine only knows the trait.
#[async_trait::async_trait]
pub trait PageSource: Send + Sync {
    async fn list_items(&self, space: Space, offset: u32, limit: u32) -> Result<AssetPage, CoreError>;
}

#[cfg(test)]
mod tests {
    use super::*;
    use models::{Asset, MediaKind, Space};
    use std::sync::Mutex;

    fn asset(id: i64, ver: i64) -> Asset {
        Asset {
            id, unit_id: id + 9000, cache_key: format!("ck{id}"), filename: format!("IMG_{id}.jpg"),
            media_kind: MediaKind::Photo, taken_at: Some(id * 10), added_at: Some(1),
            width: Some(100), height: Some(100), file_size: Some(1),
            space: Space::Personal, server_version: Some(ver),
            ..Default::default()
        }
    }

    pub struct FakeSource {
        pub pages: Vec<AssetPage>,
        pub calls: Mutex<Vec<(u32, u32)>>,
    }

    #[async_trait::async_trait]
    impl PageSource for FakeSource {
        async fn list_items(&self, _space: Space, offset: u32, limit: u32) -> Result<AssetPage, CoreError> {
            self.calls.lock().unwrap().push((offset, limit));
            let idx = (offset / limit) as usize;
            Ok(self.pages.get(idx).cloned().unwrap_or(AssetPage { assets: vec![], total: 0 }))
        }
    }

    #[tokio::test]
    async fn fake_source_returns_pages_in_order() {
        let src = FakeSource {
            pages: vec![
                AssetPage { assets: vec![asset(1, 1), asset(2, 1)], total: 3 },
                AssetPage { assets: vec![asset(3, 1)], total: 3 },
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
