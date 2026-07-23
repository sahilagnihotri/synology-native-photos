//! Pure data types for synology-native-photos. No I/O.

uniffi::setup_scaffolding!();

pub const CRATE_MARKER: &str = "models";

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum Space { Personal, Shared }

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum MediaKind { Photo, Video, Unknown }

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum ThumbnailSize { Sm, M, Xl }

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionState { Valid, Expired, Invalid }

#[derive(uniffi::Record, Clone, Debug)]
pub struct Connection {
    pub host: String,
    pub verify_tls: bool,
    pub pinned_cert_der: Option<Vec<u8>>,
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
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct Album {
    pub id: i64,
    pub name: String,
    pub item_count: u32,
    pub cover_cache_key: Option<String>,
    pub space: Space,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct CrawlProgress {
    pub space: Space,
    pub done: u64,
    pub total: u64,
    pub complete: bool,
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
        };
        assert_eq!(a.id, 42);
        assert_eq!(a.space, Space::Personal);
        assert_eq!(a.media_kind, MediaKind::Photo);
        assert_eq!(a.width, Some(4032));
    }

    #[test]
    fn connection_shape() {
        let c = Connection {
            host: "https://192.168.1.10:5001".to_string(),
            verify_tls: true,
            pinned_cert_der: None,
        };
        assert!(c.verify_tls);
        assert!(c.pinned_cert_der.is_none());
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
}
