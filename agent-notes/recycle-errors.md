
---
## recycle-errors worker (2026-10-16)
Measured:
- list_folder previously collapsed every DSM code into UnexpectedResponse via decode_envelope, so list_recycle_photos could not tell 408 from a network drop; at depth 0 it returned Ok(vec![]) for any non-auth error.
- Fix: list_folder returns ListError::{Dsm(code), Core(err)}. Root: only 408 gives empty. Subfolder: skip only 407/408. Everything else propagates.
- Falsified (old behaviour restored, tests kept): 4 of 6 new tests FAILED (root 5xx, root network, root permission, subfolder network). The 408 root, subfolder 408 and subfolder auth tests pass under both, as they pin behaviour that must not regress.
- Fixed: synology-api 31 recycle_mock tests pass (25 before), full synology-api suite green, photoscore 66 passed.
- clippy: only warning is too_many_arguments in browse.rs:543 (not ours).
- Note: a 5xx with non-JSON body surfaces as Decode, not Network (fs_get_body does not check status). Still an Err.
