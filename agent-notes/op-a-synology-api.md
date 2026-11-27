# op-a-synology-api, 2026-11-27

## VF-3 upload skip flag encodings
- Test `upload::tests::upload_skip_flag_accepts_number_and_string_encodings` written first.
  `cargo test -p synology-api --lib upload_skip_flag` FAILED before the fix:
  `upload.rs:218: blSkip 1 must read as skipped`.
- Fix: `upload_was_skipped` accepts JSON true, number 1, strings "1", "true", "yes" (any case).
  Everything else (false, 0, "0", "", null, 2, "x", missing data) is not a skip. The real
  skip reply shape on this NAS is still unverified (R2-3 note); no shape was invented.
- After: fmt, clippy -D warnings clean, `cargo test -p synology-api` all green.
