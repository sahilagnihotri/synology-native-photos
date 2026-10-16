
---
## recycle-check (worker recycle-check, 2026-10-16, single context)

Commits: b5a3d2b (api), 191915d (core + bindings + fake), 4da7a7f (app + tests).

### Measured
- cargo test -p synology-api: all green, 6 new recycle_bin_status mock tests in tests/recycle_mock.rs.
- cargo test -p photoscore: lib 66 passed (2 new: reads the setting, no login gives Auth).
- cargo clippy -p synology-api -p photoscore --all-targets: no warnings in new code. Existing
  photoscore warnings unchanged (too many arguments, loop counter `restored`, two `to_vec`).
- cargo fmt --check on photoscore was already failing before this work (not touched).
- Swift unit tests: 490 passed before the app change, 498 passed after (8 new), 0 failed, 0 skipped, exit 0.

### Falsification (each mutation, run, observed fail, restored)
API (recycle.rs mapping):
- Swap Enabled/Disabled, map missing to Enabled, propagate every error: 4 of 6 failed
  (enabled, disabled, missing field, permission error). Auth/OTP tests passed as expected.
- Fold every error into Unknown: auth and OTP propagation tests failed.
photoscore facade: return Enabled without calling the API: reads_the_user_home_setting failed.
App (DeleteController, fake core only, never the NAS), exit 65 each time:
- M1 remove the disabled gate in requestDelete: disabledRecycleBinRaisesNoConfirmAndNeverDeletes, recycleBinStatusIsFetchedOnEveryRequest failed.
- M2 drop the confirm guard and the stale pending clear: disabledRecycleBinClearsAnEarlierPendingRequest failed.
- M3 cache the status on the controller: recycleBinStatusIsFetchedOnEveryRequest (and the stale pending test) failed.
- M4 Unknown uses the "can be restored" wording: unknownRecycleBinWarnsAndDeletesOnlyOnConfirm, recycleBinWordingIsPinned failed.
- M5 Unknown blocked like Disabled: unknownRecycleBinWarnsAndDeletesOnlyOnConfirm failed.
- M6 Enabled blocked: enabledRecycleBinRaisesTheRecoverableConfirmAndDeletesOnConfirm, confirmingTwiceDeletesOnce failed.
- M7 status error silently treated as Unknown: recycleBinStatusErrorRaisesNoConfirmAndSurfacesTheError failed.
  (M6 and M7 ran together; they hit disjoint tests.)
Not independently falsifiable: the confirmDelete `status != .disabled` guard alone, since requestDelete never
leaves pending ids behind for a disabled bin. It is defense in depth; M2 shows the pair is covered.

### Product decision (reversible)
- Disabled: no confirm, no delete, a "Recycle Bin Is Off" notice with the DSM path.
- Unknown (non-admin account, refused call, missing field): confirmable, with a plain warning that the delete
  may be permanent. Reverse by blocking Unknown too (one guard in requestDelete).
- Status is read on every request, no cache.
- Auth, OTP and Network errors from the status read propagate: no confirm, error alert shown.
- Other DSM error codes (including 105 permission, and session codes 106/119 which map_error_code does not
  treat as Auth) become Unknown.

### Discovered
- DeleteController.errorMessage was never shown anywhere in the UI, so a failed everyday delete or undo was
  silent. Now shown by an alert in DeleteConfirmModifier ("Something Went Wrong").
- requestDelete is now async; RootView call sites wrap it in Task.
- Not tested on the real NAS with the non-admin photosclient user; expected to give Unknown.
