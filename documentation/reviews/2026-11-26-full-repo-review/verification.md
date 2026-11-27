# Verification of the 2026-11-26 fixes

Date: 2026-11-27. Scope: every commit from `1c2c107` to `6e4d397` (60 commits).

## Method

Each fix commit was reverted in a throwaway clone under `$TMPDIR`. Its tests
were run and had to fail, then the revert was undone and they had to pass.
Where a revert alone could not tell, a mutant of the changed line was used.
A separate confirmer then re-checked every defect claim; a claim it could not
reproduce was dropped. The clones were deleted afterwards. The exported UniFFI
surface was unchanged (64 exports before and after). Nothing touched the real
NAS; every network test runs against a localhost mock.

## Results

- 50 of 60 commits verified by falsification.
- Confirmed defects, now fixed with tests seen failing first:
  - `80d4210` (R3-7) REGRESSION: a `taken_at` near `i64::MIN` failed the whole
    date histogram. Fixed in `78772e6`. It had been filed as AV-10 and called
    pre-existing, which was wrong.
  - `61dbe05` (AV-1): the thumbnail comma check had no test that guarded it.
    The test input was caught first by the generic guard. Fixed in `2ad2460`.
  - `828f948`: the comma guard accepted `, /` (comma, space, absolute path),
    the comma lookalikes U+FF0C, U+FE50 and U+FE10, the NFKC dot form U+FE30,
    and U+FE19, U+2028, U+2029, U+061C, U+00AD, U+2060. Fixed in `2ad2460`.
  - `8d60373`: no test proved the delete check lists the delete's own parent,
    and a listing entry without `isdir` read as a file, so the delete went
    ahead. Fixed in `2ad2460`.
  - `recycle_thumbnail` accepted a non 2xx reply as bytes. Fixed in `2ad2460`.
  - `05240b6`: no test covered the pending fingerprint reset or the 20 percent
    boundary. Tests in `5d56183`.
  - `25fac1e` and `1e86fdd`: the prefetch hunk and `dismantleNSView` were
    untested. Tests in `515dbd4`.
- Refuted: the claim against `d2aa0c1`. Two reverts had masked each other.
- Open gaps (no defect reproduced, coverage or quality only): VF-1 to VF-12
  in `TODO.md`.

## Record corrections

`Fixed.md` overstated the evidence: R3-7 was called fixed, AV-1 was said to
have "three tests failed first", and the header said every fix had a test
seen failing. `61dbe05` had no guarding test, and `7b296d3` and `7705f48` were
checked by reading. Also corrected: the Rust count, the missing R6-9 hash
(`e18512b`), the unnamed R6-4, R1-3c and R4-12b, the missing `828f948`, the
REV-F7 count (13 commits covering 16 IDs), and an AV-12 entry that is not in
the AV report (now NAS-COMMA-1).

## Gates on the final tree

- `scripts/ci/ci.sh core`: exit 0. Rust 458 passed, 0 failed, 1 ignored, 5
  script tests.
- Xcode unit run: `TEST SUCCEEDED`. 514 Swift Testing tests in 54 suites plus
  6 XCTest.
- `scripts/macos/ffi-smoke.sh`: exit 0.
- `scripts/windows/check-core.sh`: exit 0.

Not done: nothing was run in the live app or against the real NAS.

## Follow up, same day: the open items

VF-3 to VF-12, AV-7, AV-8, AV-9, AV-11 and the REV-F6 script part were fixed
by five workers and each fix was broken on purpose by a separate checker. Two
fixes were incomplete and corrected: AV-9 only compared with the previous page
(`5a2f88f`), and the REV-F6 test passed when the failure was reported as a pass
(`6cbf018`). Gates on `5027e0c`: Rust 477 passed, 0 failed, 1 ignored; 529
Swift tests; FFI smoke and Windows cross check pass. New items found by the
checkers are VC-1 to VC-6 in `TODO.md`.
