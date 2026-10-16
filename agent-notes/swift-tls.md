
---
## swift-tls worker, skip-TLS toggle no longer persisted (2026-10-16)

Measured:
- Fixed state: full MySynologyPhotosTests run exit 0 (3 new tests in LoginViewModelTests.swift, struct LoginPreferencesTests).
- Falsification: restored HEAD LoginPreferences.swift, run exit 65 with all 3 new tests failing (untrustedTlsIsNotPersistedAcrossSaveAndLoad, previouslyStoredTrueIsClearedOnLoad, storedTrueIsClearedEvenWithoutSavedHost). Fix restored, run exit 0.
- One earlier falsification run exited 65 with "test runner hung before establishing connection" (not a test failure); retry produced the real failures.
- New test file was avoided because app/MySynologyPhotos.xcodeproj is tracked and a new file would need a pbxproj change; tests were appended to the existing file instead.
- -quiet output gives no pass count, so the 470 baseline total was not re-counted.
