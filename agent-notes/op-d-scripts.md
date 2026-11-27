
## op-d-scripts 2026-11-27

- VF-10: mutants of ci.sh run against scripts/tests/test-ci.sh (CI_SCRIPT). Before: dropping `--locked` from the test stage and dropping `failed -eq 0` both gave "all passed" (masked). Added a nolock case expecting `^FAIL test` and a swift case with clean exit and failed=2. After: test-stage mutant fails "tree without a lockfile fails the test stage (--locked)", failed mutant fails "failed count alone fails with a clean exit". Dropping clippy's `--locked` was already caught.
- VF-11: `git check-ignore -v platforms/macos/PhotosCore.xcframework/Info.plist` printed nothing before (only build/ matched). Added `*.xcframework/`; now matched at .gitignore line 41, also at platforms/macos/Frameworks/. `git ls-files | grep -c '\.xcframework/'` is 0, so nothing tracked is hidden.
- REV-F6 (script part): setup.sh --verify no longer runs cargo; a missing bindgen source now fails. Added SETUP_REPO_ROOT override and 3 cases in test-setup-args.sh. Mutants (verify branch disabled, missing-source check disabled) each make exactly one case FAIL.
- Not touched (outside owned paths): project.yml DEVELOPMENT_TEAM comment, Fixed.md bundle ids.
