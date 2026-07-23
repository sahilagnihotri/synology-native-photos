//! Pure data types for synology-native-photos. No I/O.

pub const CRATE_MARKER: &str = "models";

#[cfg(test)]
mod tests {
    #[test]
    fn crate_marker_is_present() {
        assert_eq!(crate::CRATE_MARKER, "models");
    }
}
