//! Cross-boundary integration smoke test.
//!
//! Instantiates PhotosCore through the public constructor from an external
//! crate, the same way UniFFI-generated Swift scaffolding would call in:
//! proves the exported surface (not just core_version) is reachable and
//! usable from outside the crate.

use photoscore::PhotosCore;

#[test]
fn public_constructor_is_reachable() {
    let dir = std::env::temp_dir().join(format!("photoscore-boundary-{}", std::process::id()));
    std::fs::create_dir_all(dir.join("db")).unwrap();
    std::fs::create_dir_all(dir.join("cache")).unwrap();
    let core = PhotosCore::new(
        dir.join("db").to_string_lossy().into(),
        dir.join("cache").to_string_lossy().into(),
    )
    .expect("core constructs");
    assert_eq!(core.asset_count(models::Space::Personal).unwrap(), 0);
}
