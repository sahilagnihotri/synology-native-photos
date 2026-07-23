//! The UniFFI boundary crate exposing PhotosCore to Swift.

uniffi::setup_scaffolding!("photoscore");

/// Trivial cross-boundary smoke function. Returns the core crate version.
/// Proves Swift can call into Rust over UniFFI before the full PhotosCore lands.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[cfg(test)]
mod tests {
    #[test]
    fn core_version_matches_cargo_pkg_version() {
        assert_eq!(crate::core_version(), env!("CARGO_PKG_VERSION"));
        assert_eq!(crate::core_version(), "0.1.0");
    }
}
