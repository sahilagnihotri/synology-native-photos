# Feasibility Research — Synology Native Photos (2026-07-23)

Goal: build a native Mac app (Windows later) that acts as an Apple-Photos-like client to a Synology NAS, to support migrating off iCloud while keeping a double backup.

This document distills completed research from three parallel briefs (Synology API, iCloud/Synology sync semantics, Mac app architecture) plus a synthesis pass. Reliability labels are carried through from the source research: **high** = official docs or proven by multiple independent open-source clients; **medium** = forum evidence, single source, or reasoned inference; each claim also notes what it is based on. A separate section at the end lists everything that still needs empirical verification on the user's own NAS/setup before it can be trusted.

---

## 1. Can a third-party app do this? (API capabilities)

**Bottom line (confidence: high):** a third-party desktop client can list, download, read metadata, and, per the API surface, delete and write metadata for photos in Synology Photos on **DSM 7.x** today, via the private-but-reverse-engineered DSM Web API reached through `/photo/webapi/entry.cgi`. Multiple production open-source clients (Rust, Python, JS/Node, Home Assistant) prove the read/download path works. There is **no official Synology Photos API contract**; only the login API is officially documented.

### Capability matrix

| Capability | Reliability | Based on / notes |
|---|---|---|
| **List** items/folders/albums | high | `SYNO.Foto.Browse.Item` `method=list` with `folder_id`/`offset`/`limit`/`sort_by`/`sort_direction`/`type`. Proven by multiple OSS clients. |
| **Download** originals | high | `SYNO.Foto.Download` / `SYNO.FotoTeam.Download` using `unit_id` + `cache_key`. Proven by OSS clients (e.g. Rust `syno-photos-util` export). |
| **Thumbnails** | high | `SYNO.Foto.Thumbnail` `method=get` with `id`, `cache_key`, `type=unit`, `size` = sm(240px) / m(320px) / xl(1280px), scaled on shorter edge preserving aspect ratio. `cache_key` (format `{unit_id}_{timestamp}`) obtained by listing with `additional=["thumbnail"]`. Passing `_sid` in the URL makes it work outside the cookie session. |
| **Metadata read** | high | `get_item_info` with `additional` = exif, gps, tag, description, person, address, thumbnail, resolution, orientation. `get_exif`, `get_tag` also exist. |
| **Delete** | medium-to-high | `delete` method **is exposed** on `SYNO.Foto.Browse.Item` / `SYNO.FotoTeam.Browse.Item` (zeichensatz unofficial docs, high-reliability source). Method *existence* verified; exact request body and soft-vs-hard semantics **not** verified. No OSS wrapper has wrapped item-delete yet (a wrapper gap, not an API limitation). |
| **Metadata write** | medium-to-high | `set`, `add_tag`, `rename` exposed on `...Browse.Item`. Confirmed writable via Python wrapper: `set_item_description`, `set_item_favorite`, `set_item_rating`. Writable fields beyond those (e.g. EXIF taken-time, GPS) are undocumented. |
| **Albums** | high | `SYNO.Foto.Browse.Album`; Python wrapper confirms `create_album`, `create_normal_album`, `delete_album`, `rename_album`, `share_album`, `list_items_in_album`. |
| **Search** | high | `SYNO.Foto.Search.Search` (`list_item`, `count_item`) and `SYNO.Foto.Search.Filter.list`. |
| **Faces / people** | high | `SYNO.Foto.Browse.Person`: `list_persons`, `get_person`, `rename_person`, `merge_persons`, `separate_person`, `list_items_by_person`, `list_faces`. Also Geocoding (`SYNO.Foto.Browse.Geocoding` / `list_geocoding`) and AI Concepts (object/scene tags). |
| **Auth + 2FA** | high | See auth flow below. Officially documented for the login API; proven by OSS clients including 2FA. |

Notes on scope and shape of the API:

- **Personal vs shared space:** `SYNO.Foto.*` = Personal Space (richer: albums, people, search); `SYNO.FotoTeam.*` = Shared Space (fewer APIs). Both have parallel `Browse.Folder` / `Browse.Item` / `Thumbnail` / `Download` namespaces.
- **Pagination:** offset/limit everywhere. Default limit ~1000; community code runs `limit`=4000–5000 successfully. (medium) No documented server-side rate limit — only DSM's generic auth auto-block. Throttle client-side; load-test before bulk ops.
- **DSM 7 only.** DSM 6 used the unrelated, deprecated PHP "Photo Station" API (a different product). (high)
- Endpoints `entry.cgi` / `query.cgi` / `auth.cgi` are interchangeable.
- Some reverse-engineered params (`ignore`, `recursive`) appear in code but are not actually implemented. (medium)

### The critical unknown — is API delete soft or hard? (must test empirically)

It is **not documented** whether `SYNO.Foto.Browse.Item` `delete` performs a soft delete (recoverable / recycle bin) or a hard delete. No `SYNO.Foto.Browse.RecycleBin` API was found. Whether the DSM shared-folder Recycle Bin (if enabled on the photos share, a filesystem-layer feature) catches API-initiated deletes is also unverified. **Treat API delete as effectively destructive until proven otherwise on a throwaway photo on a live DSM 7 NAS.** This must gate any delete feature. (Reliability of the caveat: medium.)

### Auth flow specifics (high)

- **Login:** `POST`/`GET` to `/photo/webapi/auth.cgi` (or `entry.cgi`/`query.cgi`) with `api=SYNO.API.Auth&method=login&account=<U>&passwd=<P>`. Returns a session id `sid` (and a device id `did`).
- **Versions:** `SYNO.API.Auth` supports v3–v7 (v6/v7 current on DSM 7; v3 still works for Photos).
- **Session:** pass credentials on every subsequent call either via cookie or as `_sid=<sid>` query param.
- **CSRF hardening:** add `enable_syno_token=yes` to login to get a `synotoken`, which must be sent as the `X-SYNO-TOKEN` header (or `SynoToken` param) on state-changing calls.
- **2FA / OTP:** if 2FA is enabled, login returns an auth error (commonly 403 "need 2fa" or 406 depending on DSM version); the client re-sends login with `&otp_code=<6-digit>`. DSM 7.2 added approve-on-device / passwordless as alternatives, but `otp_code` remains the programmatic path. (This is the root cause of the recurring Home Assistant "DSM 7 2FA" issues.)
- **Endpoint discovery:** query `SYNO.API.Info` with `query=all` at runtime to discover available APIs and their min/max versions rather than hardcoding — this is the recommended mitigation for the no-contract / version-drift problem.
- **Logout:** `method=logout`.
- **Transport:** HTTPS expected (examples use `:5001`). Reachable via direct IP, DDNS, or QuickConnect relay (QuickConnect only changes the host, not the API).
- **Shared albums** use a separate path `/photo/mo/sharing/webapi/entry.cgi` with `SYNO.Core.Sharing.Login` + `x-syno-sharing` header + passphrase.

### Known open-source clients to learn from

- **Unofficial API docs:** `github.com/zeichensatz/SynologyPhotosAPI` and `github.com/N4S4/synology-photos-api` (the primary references for endpoint behavior).
- **Rust:** `Caleb9/syno-photos-util` (login, list-albums, list, export, copy album→folder); `Caleb9/syno-photo-frame` (slideshow; also targets Immich).
- **Python:** `N4S4/synology-api` (comprehensive; powers `N4S4/homeassistant-synology-pro`); plus the `synophotos` CLI/PyPI package.
- **Node/JS:** `kwent/syno` (DSM REST CLI).
- **Home Assistant:** core `synology_dsm` integration added Synology Photos as a media source (PR #77784).
- **Legacy (Photo Station, different product):** `creatorKoo/python-photostation`, `graingert/synopy`.
- **Not a Mac client:** `OSPhoto` is a self-hosted Photo Station replacement (server side).

There is **no existing native Swift Synology Photos client to fork.** Build the API client from scratch against the unofficial docs and verify against your own DSM.

---

## 2. iCloud / Synology data-flow truth

All rows in the propagation table below are **high-reliability / official** unless noted.

### Propagation table — what reaches iCloud/phone vs what doesn't

| Action | Propagates to iCloud + all devices? |
|---|---|
| Synology phone→NAS backup (default) | **No.** One-way; reads the local Photos library via Apple PhotoKit; never touches iCloud directly. |
| Organize / delete / tag *inside* Synology Photos on the NAS (web UI / DSM) | **No.** The NAS library is a separate destination store with no channel back to the phone. |
| Delete inside the Synology **mobile app** with "Delete from NAS and phone" set | **Yes, indirectly.** It removes the local phone original; with iCloud Photos ON, iCloud syncs that deletion everywhere. |
| Synology **"Free Up Space"** (delete originals after backup) | **Yes, dangerously.** It deletes the local phone copy (NAS copy stays); with iCloud ON that is a deletion iCloud syncs to every device. Only safe *after* iCloud Photos is off. |
| Any delete on the iPhone with iCloud ON | **Yes.** Syncs everywhere; goes to Recently Deleted for 30 days then purged (immediate if over iCloud storage quota). |

Additional facts:

- The mobile-app default deletion setting "**Delete from NAS only**" leaves the phone untouched. Deletions in the NAS web UI never reach the phone regardless of setting.
- "**Remove from iPhone**" (the storage-management prompt) removes only the local device copy without deleting from iCloud — different from a normal delete.
- **Optimize iPhone Storage** keeps smaller versions on-device and full-res only in iCloud (downloaded on demand). **Download and Keep Originals** stores the full-res file locally (subject to free space). This distinction is the single most important variable for whether Synology can back up a real original.

### The exact safe migration path off iCloud (high / official)

1. **iPhone → Settings → Photos → Download and Keep Originals.** Wait until *fully* downloaded. Needs enough free local storage or it silently stalls. (With Optimize Storage on, full-res originals live only in iCloud.)
2. **Run the Synology backup and verify** by spot-checking file sizes/dimensions on the NAS against the phone. Also set iOS "Transfer to Mac or PC = Keep Originals" to avoid HEIC→JPEG transcoding.
3. **Establish a genuinely independent second copy:** a Mac Photos library set to "Download Originals to this Mac," and/or copy the NAS photo folder to a separate external drive. RAID is not a backup; add Hyper Backup to external/offsite for the 3-2-1 rule.
4. **Only after two verified full-res copies exist,** optionally turn off iCloud Photos (Settings → iCloud → Photos; choose "Download Photos & Videos" if prompted). Turning it off with Keep Originals already on does not delete local originals; it only stops uploading. Apple purges the iCloud-stored copies **~30 days later**, so local + NAS must be complete and verified first.

Recommended backup topology: minimum double = iCloud (or phone with Keep Originals) + Synology NAS. Better triple = phone/iCloud working library + NAS (Photos app backup) + a third independent copy (Mac Photos library with downloaded originals, or periodic NAS-folder export to a separate/offsite drive). NAS should use redundant disks **and** a separate backup, because RAID is not a backup.

### Top ways to lose photos

1. **Turning off iCloud Photos while "Optimize Storage" was on and originals were never actually downloaded** — only thumbnails remain locally; full-res is lost at iCloud purge. (The classic disaster.) (high)
2. **Using "Free Up Space" or deleting the camera roll while iCloud Photos is still ON** — you are deleting from iCloud and every device, not just trimming the phone. (high)
3. **Trusting "Optimize Storage + Synology backup" captured originals** when it silently backed up optimized/lower-res versions. (medium — see caveat below.)
4. **Letting "Download and Keep Originals" stall** due to insufficient local storage and not noticing it never finished. (high)
5. **Treating the NAS as the only copy** (single point of failure: drive/RAID failure, ransomware, accidental delete). (high)

> **DANGER caveat (medium reliability, forum evidence):** with Optimize Storage on, iOS does **not** reliably force-download every full-res original for third-party backup apps. Full-res requests require the app to set network access in `PHImageRequestOptions`; background upload/resource extensions are frequently never scheduled while iCloud Photos is enabled, and optimized assets can be silently skipped. Practical rule: do **not** trust on-demand fetch — download originals to the device first.

### Full-res / HEIC / Live Photo / RAW handling caveats

- **HEIC:** supported and uploaded as-is by the mobile backup (when Keep Originals is set). (high)
- **HEIC→JPEG conversion caveat:** applies to Photo Request upload links and to iOS "Automatic" transfer mode — **not** to standard app backup when Keep Originals is set. (high)
- **Live Photos:** stored on the NAS as **two separate files** (an HEIC still + an HEVC/MOV motion file). Both components are preserved but the "live" linkage is effectively lost on the NAS side and is not reconstructed. (high)
- **RAW:** wide format support — dng, cr2, cr3, crw, nef, arw, sr2, srf, raf, rw2, orf, pef, ptx, 3fr, erf, mef, mos, k25, kdc, dcr, x3f. (high)

**Design implication for the app:** because the NAS side never propagates back to the phone, the Mac client deleting/organizing on the NAS is **safe with respect to iCloud** — it cannot touch the phone. The danger is entirely on the phone/iCloud side and in the app's own destructive NAS operations (hence: keep originals immutable, and verify delete semantics before shipping delete).

---

## 3. Recommended Mac app architecture

All items are **high-reliability** unless noted.

### UI

- **App shell:** SwiftUI for the app chrome.
- **Photo grid:** **AppKit `NSCollectionView`** with `NSCollectionViewDiffableDataSource`, wrapped in `NSViewRepresentable` so the rest stays SwiftUI. This is the load-bearing decision. **Why not `LazyVGrid`:** at 10k+ thumbnails plain SwiftUI `LazyVGrid` stutters on fast scroll — the SwiftUI structs are cheap but their AppKit backing views are not, and LazyVGrid's recycling is far less aggressive than NSCollectionView's pool-based cell reuse. LazyVGrid is fine only up to a few hundred to a few thousand items; NSCollectionView scrolls smoothly at 50k. (This mirrors how Apple's own Photos works conceptually: a reusing collection view.)
- Inside cells you can still host SwiftUI via one `NSHostingView` per cell updated on reuse (WWDC22 "Use SwiftUI with AppKit"). The `flocked/AdvancedCollectionTableView` package extends NSCollectionView with SwiftUI-style item registration and built-in QuickLook.
- **Detail / preview:** shared `QLPreviewPanel` with a `QLPreviewPanelDataSource`, or NSCollectionView's `isQuicklookPreviewable` for spacebar preview.
- **Why not Catalyst:** it reads as an iPad port and gives worse grid performance and native feel than AppKit for a Photos-grade Mac app.

### Local index, thumbnail cache, sync

- **Local index — GRDB (SQLite), not Core Data.** One row per asset: id, cache_key, filename, taken date, dimensions, hash, album membership, sync flags. Drive the grid **entirely from the local DB** (via GRDB `ValueObservation`) so remote latency never blocks scrolling; thumbnails load asynchronously into reused cells. Prefer GRDB over Core Data: less multithreading friction for a sync-heavy app, and a Rust core cannot share Core Data anyway. Mirrors Apple's Photos.app (local `Photos.sqlite` + a derivatives/proxies thumbnail folder).
- **Thumbnail cache — two-tier, keyed by `cache_key`.** Bounded `NSCache` in memory for the visible window; on-disk cache (Application Support / Caches) named by `id + cache_key + size`. Fetch via `SYNO.Foto.Thumbnail`. **Invalidate when `cache_key` changes on the NAS** (it changes when the asset is re-derived). Prefetch ahead of scroll direction using NSCollectionView prefetching.
- **Sync — crawl + delta reconciliation.** First run: a full paginated crawl of items into SQLite (metadata only — id, cache_key, timestamps, hashes — **no eager thumbnail download**). Thereafter: delta reconciliation — page listings ordered by modified/taken time, diff against the local table (new / changed cache_key / deleted), update rows in a transaction. The UI observes the DB and renders instantly from local rows; thumbnails and originals stream in lazily and cache. This decouples scroll performance from NAS latency, which is the key to 50k photos feeling smooth. (Sync/reconciliation strategy: medium — inference.) Background sync via **`NSBackgroundActivityScheduler`** (the macOS-correct scheduler, not iOS `BackgroundTasks`).

### Reusable-core options

Put **all shared logic (Synology API client, sync engine, DB layer, models) behind a clean core boundary from day one,** even while shipping Mac-only. Two credible options:

- **Rust + UniFFI** (recommended for maximum Windows flexibility): one tested, memory-safe crate; UniFFI (Mozilla, built to share Rust across Firefox platforms) compiles the core to a shared library and generates Swift bindings, giving a fully native SwiftUI/AppKit Mac UI over shared logic. The same crate later powers a Windows UI (WinUI3/C# via third-party UniFFI C# bindings, or a Rust-native UI like Slint/egui, or Tauri). **Trade-off:** a Rust↔Swift FFI boundary to design (value types, error mapping), no shared UI, and learning Rust.
- **Pure-Swift SwiftPM core** (recommended if you want one language): Swift-on-Windows is production-credible in 2026 (Swift.org Windows workgroup formed Jan 2026; Readdle and The Browser Company ship production Windows apps in Swift; SwiftPM/Swift Build support Windows). **Trade-off:** there is **no Apple UI framework on Windows**, so the Windows GUI is fully separate (Win32/WinUI) either way, and Foundation/Dispatch on Windows is still hardening. The core must be a SwiftPM package with no UIKit/AppKit imports.
- **Rejected alternatives:** Kotlin Multiplatform (adds a JVM/Native toolchain and Swift-interop boilerplate with no advantage here); re-implement in C#/.NET later (lowest setup but highest duplication, risks Mac/Windows behavior drift).

Either way, **Windows becomes a UI project, not a rewrite** — the point of the boundary. This choice is hard to reverse cheaply, so **decide it before writing much code.**

### Auth/secrets, connectivity, editing

- **Auth / secrets:** store DSM credentials or session token in the **Keychain** (Data Protection Keychain, Secure Enclave-backed on Apple Silicon/T2) — never UserDefaults. Persist the `sid`; re-run `SYNO.API.Auth` login on 401/expiry.
- **Connectivity (LAN / Tailscale / remote):** support both LAN (local IP/hostname — fast, preferred for originals) and remote (QuickConnect relay or DDNS/HTTPS; a Tailscale/VPN address is just another host). Store both, probe on launch with `NWPathMonitor` (Network framework), prefer LAN when reachable and fall back to remote.
- **Editing (later phase) — non-destructive, upload-as-new (medium):** Synology Photos has **no XMP-sidecar write-back** for HEIC/MOV and stores its own edits in a proprietary DB, so edits cannot be round-tripped into it. Model: download the original, apply edits non-destructively (store an edit recipe/sidecar locally in your own DB), render an edited copy, and **upload it as a new asset** (or into an "Edited" folder) rather than overwriting the original. Keep originals immutable — destructive overwrite of NAS originals is dangerous for v1. Metadata-only edits (title, rating, album membership) can go back through the API where supported.

---

## 4. MVP phasing and honest effort estimate

**Phasing** (build the core boundary clean in Phase 1 so Phase 4 is UI-only):

- **Phase 0 — spike + de-risk (~1–2 weeks):** API spike, empirical delete-semantics verification, and the core-language decision. Do this before committing to the stack.
- **Phase 1 — MVP, read-only browse (~4–8 weeks):** auth + 2FA + Keychain; paginated list into SQLite; `NSCollectionView` grid over the local index; on-disk thumbnail cache; detail view via QuickLook / download original. Smallest genuinely useful version; fully backed by high-reliability, already-proven capabilities. The grid + local SQLite index + thumbnail cache + auth is the bulk of the real engineering.
- **Phase 2 — manage (~4–8 weeks):** albums + search + people/faces browse; **delete** (only after empirically confirming delete semantics on a throwaway); metadata edits (favorite/rating/description/title); background delta sync. Delta reconciliation and safe destructive operations are the hard parts.
- **Phase 3 — edit + polish (~6–10+ weeks):** non-destructive pixel editing with upload-as-new; LAN/remote auto-switching; video if in scope. Highly dependent on whether pixel editing and video are included (both can be deferred).
- **Phase 4 — Windows (~6–12 weeks):** extract/confirm the shared core, build the Windows UI on top of it. A genuine second UI, cheaper than a rewrite only because the core was built clean.

**Honest effort estimate (solo dev):** this is a **multi-month solo build, not a weekend project** (medium — inference). For one experienced developer, part-time to full-time, ballpark to a polished Mac-only app through Phase 3 is **~4–7 months** of focused effort; add several more for Windows. Adding Rust as a new language, video handling, or Mac App Store sandboxing pushes toward the high end.

**Bottom line:** the project is feasible and the core capability (including delete) is real. The two things that will actually bite: (a) the undocumented, drifting Photos API — verify delete semantics and mutating-verb params on your own NAS before Phase 2; and (b) the iCloud migration itself, a data-safety procedure independent of the app — do the "Download and Keep Originals → verify → second independent copy → then disable iCloud" sequence before trusting anything.

---

## 5. Open questions / risks needing verification before building

### Verified — build on these confidently (high)

Login + 2FA; list albums/items/folders; download originals; thumbnails; copy; metadata-read. Proven by multiple independent OSS clients.

### Needs empirical verification — do these first, on a throwaway photo / test NAS

1. **Delete semantics** — soft (recoverable / recycle bin) vs hard delete? Undocumented. **Gate Phase 2 on this.** Also verify whether the DSM shared-folder Recycle Bin catches API-initiated deletes. (medium)
2. **Exact request bodies for mutating verbs** (`delete`, `move`, `set`, `add_tag`) — the unofficial docs list *method names only*, not params. Capture them from the Synology Photos web UI's own network traffic via browser DevTools against `/photo/webapi/entry.cgi`. (medium)
3. **Which `SYNO.Foto` method/version combos are stable across the target DSM versions** (7.0 → 7.2 → 7.3/2026). Confirm the exact DSM version(s) to support; use runtime `SYNO.API.Info` discovery, do not hardcode. (medium)
4. **Server-side rate / concurrency limits** — none documented (only DSM's generic auth auto-block). Throttle client-side; load-test before trusting bulk operations. (medium)
5. **Writable metadata fields via `set`** beyond description/favorite/rating (e.g. EXIF taken-time, GPS) — the method exists but writable fields are undocumented. (medium)

### iCloud-side risks to confirm on the user's own setup

6. Reliability of iOS 2026 force-downloading full-res for third-party backup apps under Optimize Storage — assume unreliable; download originals to device first. (medium)
7. Exact mobile-app deletion-setting labels ("Delete from NAS only" vs "…and phone") on the user's iOS build — wording has shifted across app versions.
8. Whether preserving the Live Photo motion component (HEVC MOV) as a linked Live Photo matters to the user — on the NAS it is stored as a separate file and the Live linkage is not reconstructed.

### Product-scope decisions that materially change effort

- **Core language:** Rust + UniFFI (max Windows flexibility, new language) vs pure-Swift SwiftPM core (one language, Windows GUI still fully separate, Foundation-on-Windows caveats). Hard to reverse cheaply — decide before writing much code.
- **Pixel editing** in scope for early phases or deferred (the whole edit / upload-as-new subsystem can be deferred well past MVP).
- **Video** in v1 or not (video thumbnails, streaming/transcoding, playback add significant work beyond the still-photo MVP).
- **Connectivity assumption:** is QuickConnect relay bandwidth acceptable for downloading originals, or should originals only be fetched on LAN?
- **Distribution:** direct-download (Developer ID + notarization; allows broad filesystem/network entitlements) vs Mac App Store (sandbox constraints on network and background activity, which affect architecture).
