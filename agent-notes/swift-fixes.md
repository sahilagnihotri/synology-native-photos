
---
## swift-fixes worker, 2026-10-16

Measured:
- Warnings reproduced with `xcodebuild build -quiet`: GridZoomModel.swift:27 (default argument reads a MainActor static from a nonisolated context) and ThumbnailCache.swift:103 (nonisolated peekMemory reads actor property). Both gone after fixes; the next full build printed neither.
- Fixes: `nonisolated static` on the pure constants and clamp; NSCache wrapped in an `@unchecked Sendable` holder (NSCache is documented thread safe, holder has one immutable let). `nonisolated let` on the bare NSCache was rejected by the compiler (NSCache is not Sendable).
- Editor: `PhotoEditorView.loadSource` goes through `OriginalImageCache.fullImage` (8192 cap, shares the RAM entry with the detail zoom decode). Test `PhotoEditorSourceLoadTests` loads twice and expects 1 download and the cached bytes equal to the source.
- Falsification: replaced loadSource body with a direct download plus decode (no cache). Test FAILED (exit 65, count expectation and cached file lookup). Restored, PASSED.
- Full unit run after fixes: 490 passed, 0 failed, 0 skipped, exit 0. Earlier reported 3 cache test failures did not reproduce on a quiet tree.
- Gotcha: chaining `; echo` or piping after xcodebuild puts it in the sandbox and it fails to write derived data; run it bare. xcresulttool needs to run outside the sandbox.
