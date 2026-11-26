# FC fix notes: photoscore facade, crawl and reconcile

### MOCK-1: FIXED
- commit: 6d5c7c5
- test: `core_tests::empty_recently_deleted_permanently_deletes_each_path` in core/photoscore/src/lib.rs
- failed before the fix: with FA's uncommitted `ensure_is_recycled_file` in the working tree, `empty ok: UnexpectedResponse { message: "refusing to delete a.jpg: it is not listed in /home/#recycle/Photos" }`
- passes after: `cargo test -p photoscore`: `test result: ok. 66 passed; 0 failed; 0 ignored` (lib)
- changed tests: the fixture only. It now serves one listing that shows `a.jpg` as a file (`expect(1)`, asserted), then the empty listing the post delete poll needs. The check itself is untouched.
- left open: none. The fixture also passes without FA's check (the poll then sees the file once and polls again).
