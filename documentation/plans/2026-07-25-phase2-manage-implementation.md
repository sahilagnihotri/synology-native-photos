# Phase 2 — Manage (Safe Delete, Albums, Favorites, Search) Implementation Plan

> Date: 2026-07-25
> Status: DRAFT, awaiting review. Builds on the Phase 0/1 interface contract
> (`documentation/plans/2026-07-24-phase0-phase1-interface-contract.md`) and the
> approved design (`documentation/plans/2026-07-23-synology-native-photos-design.md`).
> Phase 1 (read-only browse) is functionally complete: login+2FA+cert pinning,
> capability probe, resumable crawl + delta reconcile, windowed grid, thumbnail
> cache, QuickLook detail, Personal/Shared toggle, sign-out. This plan adds the
> first write-capable surface.

Authoritative for Phase 2 in the same sense the interface contract was for
Phase 0/1: task authors code against the exact names, signatures, and SQL
below. If something proves wrong against the real NAS, amend this doc; do not
fork silently. Every write method here is UNVERIFIED against the real NAS
until its own task's empirical probe step confirms it — the request shapes
below are the best-evidence starting point (feasibility research +
`SYNO.Foto.Browse.Item` naming conventions already confirmed for `list` in
Phase 1), not confirmed fact.

---

## 1. Goal

Add the first write-capable features to the app, in the order the design
mandates: safe (reversible) organization first, real permanent deletion only
after it is empirically proven safe. Concretely:

- **Phase 2a:** move-to-trash delete (an app-controlled trash album, not the
  raw NAS delete verb), album view/create/organize (move items between
  albums, reusing the same move primitive), trash view + restore, and the
  safety UX (confirmation + one-time second-backup acknowledgment) that gates
  every destructive action from here on.
- **Gate:** the delete-semantics probe (Phase 0 Task 7, left PENDING) must run
  and produce a verdict before any Phase 2b permanent-delete code is written.
- **Phase 2b:** real permanent-delete (only if the probe verdict says
  recoverable; otherwise "empty trash" stays a no-op label change forever,
  by design), favorites/ratings (metadata-only write, re-read after write),
  and search/filter (date, filename, metadata; people/faces if the API
  exposes it, else a documented limitation).

Non-goals for this plan: non-destructive editing (Phase 3), cross-platform
core extraction (Phase 4), QuickConnect/DDNS (Phase 4).

## 2. Why an app-controlled trash album, not the NAS's own delete

The Phase 0 probe doc (`documentation/phase0-probe-results.md`) records the
delete-semantics verdict as **still pending** — every field in that table is
literally the word "pending". That means, as of this plan, nobody knows
whether calling `SYNO.Foto.Browse.Item` `method=delete` on this DSM is
recoverable or destructive. The design's second safety invariant already
answers what to do about that: don't call it. Phase 2a implements "delete" as
a **move** of the asset into an Album this app creates and owns (name fixed,
e.g. `_App Trash` or similar — exact name decided in Task 1 below), using the
same move primitive Phase 2a needs anyway for "organize into an album". The
asset never leaves the NAS's normal album-membership graph; it is fully
recoverable by moving it back, and nothing about it depends on the probe
verdict. This is also why albums (view + organize-via-move) and trash
(view + restore) are both Phase 2a: they are the same underlying operation
wearing two different UI hats.

Real permanent-delete is deliberately kept out of Phase 2a's code path
entirely — not merely disabled behind a flag, but not implemented — until the
probe in Task 1 below produces a verdict. This mirrors how Phase 0/1 shipped
zero delete code rather than gated-off delete code, per the read-only
invariant already in `phase0-probe-results.md`.

## 3. Architecture additions

```
┌─────────────────────────────────────────────┐
│  macOS app (Swift) — additions                │
│  ├─ Delete confirm sheet + second-backup ack   │
│  ├─ Trash view (grid filtered to trash album) │
│  ├─ Album management UI (create, add-to, list)│
│  ├─ Favorite toggle (grid overlay + detail)    │
│  └─ Search bar (date / filename / metadata)    │
└───────────────┬───────────────────────────────┘
                │ UniFFI (same boundary, new methods)
┌───────────────▼───────────────────────────────┐
│  photos-core (Rust) — additions                │
│  ├─ synology-api: move.rs, album_write.rs,     │
│  │   favorite.rs, search.rs                    │
│  ├─ persistence: trash flag on assets,          │
│  │   favorite/rating columns, search indices    │
│  ├─ sync-engine: no new engine, delta already   │
│  │   picks up server-side moves/favorite changes│
│  └─ models: MoveTarget, SearchQuery, new         │
│      CoreError variant if needed (none expected) │
└───────────────┬───────────────────────────────┘
                │ HTTP(S), same transport/envelope/namespace
┌───────────────▼───────────────────────────────┐
│  Synology NAS — Synology Photos                │
│  SYNO.Foto(Team).Browse.Item (move/set/search)  │
│  SYNO.Foto(Team).Browse.Album (create/add_item)  │
│  SYNO.Foto(Team).Search.Search (list_item)       │
└────────────────────────────────────────────────┘
```

No new crates. Every write lands in `synology-api` (new modules: `move_item.rs`,
`album_write.rs`, `favorite.rs`, `search.rs`), `persistence` gains columns/
queries, `photoscore` gains facade methods, `app` gains UI. `sync-engine`
itself needs no new module: a server-side move/favorite/delete is just
another field change the existing `(id, server_version)` delta reconciler
already picks up on its next pass, provided the fields it now needs to track
(album membership, favorite, rating) are added to the row it compares.

## 4. Global constraints (apply to every task below)

1. **Fail closed.** Every new write method returns `Result<_, CoreError>`.
   An unexpected response shape, an unexpected `error.code`, or a partial
   success maps to `CoreError::UnexpectedResponse` and changes nothing
   locally. Never assume a write succeeded because the HTTP call returned
   200; only a decoded `success: true` envelope counts.
2. **Verify each endpoint against the real NAS before trusting its shape.**
   Every request/response shape in this document is UNVERIFIED (see the
   flags per task). Each task that adds a write includes a step to capture
   the real request/response against the dedicated `photosclient` NAS user
   (least-privilege, see `phase0-probe-results.md`) and record it back into
   that probe doc, the same way Phase 0's browse/auth captures were recorded.
   Tolerant decode (ignore unknown fields, never `deny_unknown_fields`)
   applies to every new response type, matching `browse.rs`'s existing
   pattern.
3. **Local state changes only after server confirms.** No optimistic local
   mutation before the server round-trip completes; the UI shows a pending/
   spinner state, then re-reads (or applies the server's own returned state)
   only on confirmed success. This matches the design's "metadata-only
   writes, re-read after write" rule, extended to every write in this phase,
   not just favorites.
4. **Never touch iCloud/phone.** Nothing in Phase 2 introduces any new
   destination beyond the same NAS host already in `Connection`. No new
   network egress target of any kind.
5. **Confirmation + one-time second-backup acknowledgment gates the first
   destructive action.** Trash-move counts as destructive for this gate
   (it changes NAS state even though it's reversible). The acknowledgment is
   asked once per account (persisted flag, not per-action) and is itself
   local-only state (UserDefaults or a small persistence table — decided in
   Task 12), never sent to the NAS.
6. **The delete-semantics probe (Task 1) is a hard gate on Phase 2b
   permanent-delete code.** No permanent-delete Rust code, FFI method, or
   Swift UI element is written before Task 1's verdict is recorded. If the
   probe proves destructive/unrecoverable, Phase 2b's permanent-delete tasks
   (17-19) are replaced by a single UI-only "empty trash is disabled on this
   NAS" state; this is decided explicitly in Task 17, not silently skipped.
7. **Every new persistence write happens inside a transaction** matching the
   existing `assets.rs`/`albums.rs` upsert style; no new table/column is
   written outside of one.
8. **No dashes in any user-facing string, code comment, doc, or commit
   message** (project-wide rule); use full stops/commas instead.

## 5. Data model additions

### 5.1 `models` crate additions (`core/models/src/lib.rs`)

```rust
/// Where a move operation sends one or more assets. Mirrors the two things
/// Synology Photos calls a destination: a named album, or (for the
/// app-owned trash mechanism) explicitly "no album" (removing membership
/// without adding to another), used by restore-from-trash.
#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum MoveTarget {
    Album { album_id: i64 },
    NoAlbum,
}

/// Search/filter parameters. All fields optional; an all-None query means
/// "no filter" and callers should prefer plain fetch_assets instead — the
/// core does not reject an empty query, but the UI should not construct one.
#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct SearchQuery {
    pub text: Option<String>,       // filename / description substring
    pub taken_after: Option<i64>,   // unix epoch seconds, inclusive
    pub taken_before: Option<i64>,  // unix epoch seconds, inclusive
    pub media_kind: Option<MediaKind>,
    pub favorite_only: bool,
    pub space: Space,
}

/// Favorite/rating are metadata-only, re-read-after-write per the design.
/// Rating is 0 (unset) to 5, matching Synology Photos' own UI scale;
/// UNVERIFIED against the real NAS (see Task 10).
#[derive(uniffi::Record, Clone, Debug)]
pub struct FavoriteState {
    pub asset_id: i64,
    pub favorite: bool,
    pub rating: u8,
}
```

No new `CoreError` variant is anticipated: `UnexpectedResponse`, `Auth`,
`Network`, `Decode`, `Storage`, `WriteRefused`, `CapabilityUnavailable`
already cover every failure mode a write introduces. If a task's real-NAS
probe reveals a genuinely new failure class (e.g. a distinct "album is full"
or "quota exceeded" error code), add a variant then, in that task, with a
round-trip test, rather than pre-guessing it here.

### 5.2 `persistence` schema additions (`core/persistence/src/schema.rs`)

```sql
-- Phase 2a: trash and album-membership tracking on assets.
ALTER TABLE assets ADD COLUMN in_trash INTEGER NOT NULL DEFAULT 0;   -- 0/1
ALTER TABLE assets ADD COLUMN trashed_at INTEGER;                    -- epoch seconds, nullable

-- Phase 2b: favorite/rating, metadata-only.
ALTER TABLE assets ADD COLUMN favorite INTEGER NOT NULL DEFAULT 0;   -- 0/1
ALTER TABLE assets ADD COLUMN rating INTEGER NOT NULL DEFAULT 0;     -- 0..5

-- Many-to-many membership: an asset can be in more than one album on the
-- NAS side; the trash album is just another row here, distinguished by
-- albums.is_trash, not by a separate table.
CREATE TABLE IF NOT EXISTS album_members (
    space      INTEGER NOT NULL,
    album_id   INTEGER NOT NULL,
    asset_id   INTEGER NOT NULL,
    added_at   INTEGER NOT NULL,
    PRIMARY KEY (space, album_id, asset_id)
);
CREATE INDEX IF NOT EXISTS idx_album_members_asset
    ON album_members (space, asset_id);

ALTER TABLE albums ADD COLUMN is_trash INTEGER NOT NULL DEFAULT 0;   -- 0/1, exactly one per space
ALTER TABLE albums ADD COLUMN is_local_only INTEGER NOT NULL DEFAULT 0; -- 1 until first server confirm

-- Phase 2b: search indices. taken_at/filename already indexed via
-- idx_assets_space_taken for the date axis; filename substring search uses
-- LIKE, which SQLite does not index well, so this adds an explicit index to
-- at least support prefix search fast and keeps substring search a
-- documented "scans a bounded local table, fine at 100k rows" cost, not a
-- claim of full-text search.
CREATE INDEX IF NOT EXISTS idx_assets_space_filename
    ON assets (space, filename);
CREATE INDEX IF NOT EXISTS idx_assets_space_favorite
    ON assets (space, favorite) WHERE favorite = 1;
CREATE INDEX IF NOT EXISTS idx_assets_space_trash
    ON assets (space, in_trash);
```

Migration rule: `schema_meta.schema_version` bumps to `2`. The migration
runner (already idempotent via `IF NOT EXISTS`) gains an explicit versioned
step for the `ALTER TABLE` statements, since `ALTER TABLE ADD COLUMN` is not
naturally idempotent the way `CREATE TABLE IF NOT EXISTS` is (SQLite errors
on adding a column that already exists) — guard each `ALTER TABLE` on
`schema_version < 2` rather than re-running unconditionally.

The trash album (`albums.is_trash = 1`) is created locally first
(`is_local_only = 1`) the first time Phase 2a needs it, then reconciled
against a real NAS album of the same name on the next crawl/create call
(Task 3); `is_local_only` flips to 0 once the server confirms the album
exists with a real `server_id`. This keeps trash usable immediately on first
run without a network round trip blocking the UI, while never pretending a
merely-local album is server-backed.

## 6. Task list

Numbered fresh for this plan (not a continuation of the Phase 0/1 numbering,
since this is a new phase document). Sized for TDD granularity like the
Phase 0/1 plan. Tasks 1 to 4 are Phase 2a foundation and can start now.
Task 1 (the delete-semantics probe) has no code dependency on the others and
should run in parallel with Task 2 to be off the critical path by the time
Task 17 needs its verdict.

### Phase 2a — safe delete (trash-move), albums, restore

**1. Run the delete-semantics probe and record the verdict (gate for Phase 2b)**

- Files: `documentation/phase0-probe-results.md` (fill in the verdict table
  already scaffolded there under "Delete-semantics verdict").
- This is the procedure already written in that doc (Phase 0 Task 7):
  confirm a throwaway asset is listed, observe DSM recycle bin/trash state,
  issue the real delete call by hand (curl, against the dedicated
  `photosclient` account), re-check post-delete state (still in
  Browse.Item list? in a trash album? SMB file gone or moved to
  `#recycle`? is there a separate permanent-delete/empty-trash API?).
- No code changes. This is a human-run probe against the real NAS, same as
  Phase 0's other empirical captures.
- Steps:
  1. Confirm reachability and a captured SID+SynoToken (reuse the Task 5/10
     Phase 0/1 login probe artifacts; do not re-derive credentials).
  2. Follow the five numbered steps already in the probe doc; fill every
     "pending" cell with the observed value.
  3. Add one line under "Verdict" stating explicitly which of the two
     branches Phase 2b follows: recoverable (real permanent-delete is
     buildable) or not recoverable (permanent-delete stays a disabled
     label forever, per the design's explicit gate).
- Commit: "Run the delete-semantics probe and record the verdict".

**2. `MoveTarget` model + `album_members` schema**

- Files: `core/models/src/lib.rs`, `core/persistence/src/schema.rs`,
  `core/persistence/src/lib.rs` (bump `schema_version` to 2, guarded
  `ALTER TABLE` migration step).
- Add `MoveTarget` as specified in section 5.1. Add the schema additions
  from section 5.2 behind a `schema_version < 2` guard.
- TDD: a migration test proving a store opened at version 1 (seed the old
  DDL directly, or reuse the fixture from `schema.rs`'s existing tests)
  upgrades cleanly to version 2 with the new columns present and defaulted;
  a second test proving re-running migrations on an already-v2 store is
  still a no-op (matches the existing `migrations_are_idempotent` test
  style).
- Commit: "Add MoveTarget model and album membership schema".

**3. `persistence::albums`: trash album bootstrap + membership queries**

- Files: `core/persistence/src/albums.rs`.
- New functions:
  - `ensure_trash_album(&self, space: Space) -> Result<Album, CoreError>`:
    returns the existing trash album for `space` if one is marked
    `is_trash = 1`, else inserts a new local-only one (`is_local_only = 1`,
    `server_id` a locally-assigned negative placeholder until reconciled,
    per section 5.2's bootstrap rule) and returns it.
  - `add_member(&self, space: Space, album_id: i64, asset_id: i64) -> Result<(), CoreError>`
    and `remove_member(&self, space: Space, album_id: i64, asset_id: i64) -> Result<(), CoreError>`,
    both idempotent (`INSERT OR IGNORE` / `DELETE` matching zero rows is not
    an error).
  - `fetch_album_members(&self, space: Space, album_id: i64, offset: u32, limit: u32) -> Result<Vec<Asset>, CoreError>`:
    windowed, same ordering as `fetch_assets`.
  - `set_trash_flag(&self, space: Space, asset_id: i64, in_trash: bool) -> Result<(), CoreError>`.
- TDD: bootstrap creates exactly one trash album per space and is idempotent
  on a second call; add/remove member round-trips and is idempotent;
  `fetch_album_members` respects the window and never leaks across spaces
  (mirrors the existing `fetch_assets_and_albums_return_upserted_rows...`
  test style in `photoscore/src/lib.rs`).
- Commit: "Add trash album bootstrap and membership queries to persistence".

**4. `synology-api::move_item` (UNVERIFIED, needs real-NAS probe step)**

- Files: `core/synology-api/src/move_item.rs` (new), `core/synology-api/src/lib.rs`
  (re-export), `core/synology-api/tests/move_item_mock.rs`.
- Candidate request shape (feasibility research confirms the method name
  space exists on `Browse.Item`; exact params NOT verified):
  ```
  api=SYNO.Foto(Team).Browse.Item
  method=move   (UNVERIFIED name; some community clients call it
                 "SYNO.Foto.Browse.Item" method="setalbumitem" or use
                 Album.add_item / Album.remove_item pairs instead of a
                 single move; this task's probe step decides which shape
                 the real NAS actually exposes and this doc is updated to
                 match)
  version=<pinned>
  id=[<asset_id>,...]
  target_album_id=<id>          (Album target)
  ```
  Function signature (this part IS locked regardless of which underlying
  wire shape wins):
  ```rust
  pub async fn move_items(
      transport: &Transport,
      sid: &str,
      space: Space,
      asset_ids: &[i64],
      target: MoveTarget,
      version: u32,
  ) -> Result<(), CoreError>;
  ```
- Steps:
  1. Write the mock-server test first (TDD): stub `success: true` and
     `success: false` responses, assert `move_items` returns `Ok(())` /
     the mapped `CoreError` respectively. Red first.
  2. Implement against the candidate shape above to go green against the
     mock.
  3. **Real-NAS probe sub-step (manual, recorded):** against the dedicated
     `photosclient` account and a throwaway asset (not the delete-probe
     asset; a second disposable one), issue the real call by hand, confirm
     the actual method name and param shape, update both this doc's
     candidate shape and the implementation to match. Record the captured
     shape into `phase0-probe-results.md` under a new "Move/organize probe"
     section, same style as the existing browse capture.
  4. If the real NAS instead exposes the operation as `Album.add_item` /
     `Album.remove_item` pairs rather than a single move verb, implement
     `move_items` as remove-then-add against those two calls internally;
     the public signature above does not change either way.
- Tolerant decode: the success envelope for a write call is just
  `{"success": true}` with no `data` payload expected; anything else in
  `data` is ignored, not validated.
- Commit: "Add move_items to synology-api, verified against the NAS".

**5. `persistence` + `synology-api` wiring: local-first move with server
confirm**

- Files: `core/photoscore/src/lib.rs`.
- New facade method:
  ```rust
  pub async fn move_assets(
      &self,
      space: Space,
      asset_ids: Vec<i64>,
      target: MoveTarget,
  ) -> Result<(), CoreError>;
  ```
- Behavior (constraint 3 from section 4: server confirms before local
  mutation): calls `synology_api::move_items` first; only on `Ok(())` does
  it update `album_members` (and `assets.in_trash`/`trashed_at` if `target`
  is the trash album or `NoAlbum` restoring out of it) inside a single
  transaction. On any error, no local state changes and the error
  propagates fail-closed.
- TDD: mock-server test (reusing the `core_at`/mockito pattern already in
  `photoscore/src/lib.rs`'s test module) proving (a) success updates
  `album_members`/`in_trash` correctly, (b) a mocked failure response
  leaves the local DB completely unchanged (assert row absent/flag
  unchanged), (c) moving to the trash album sets `in_trash=1` and
  `trashed_at` to a non-null value, (d) moving from trash back to
  `NoAlbum` (restore) clears both.
- Commit: "Wire move_assets through PhotosCore with server-confirm-first semantics".

**6. `delete_to_trash` and `restore_from_trash` facade convenience methods**

- Files: `core/photoscore/src/lib.rs`.
- These are thin, named wrappers over `move_assets` + `ensure_trash_album`,
  because the Swift delete-confirm flow and the trash-view restore flow
  want obviously-named, single-purpose calls rather than every call site
  constructing a `MoveTarget::Album` by hand and having to know the trash
  album's id:
  ```rust
  pub async fn delete_to_trash(&self, space: Space, asset_ids: Vec<i64>) -> Result<(), CoreError>;
  pub async fn restore_from_trash(&self, space: Space, asset_ids: Vec<i64>) -> Result<(), CoreError>;
  pub fn fetch_trash(&self, space: Space, offset: u32, limit: u32) -> Result<Vec<Asset>, CoreError>; // local read, no network
  ```
- TDD: `delete_to_trash` on a freshly-crawled asset ends with it absent from
  `fetch_assets`'s normal (non-trash) results and present in `fetch_trash`;
  `restore_from_trash` reverses that exactly; both are proven via the mock
  server pattern used in Task 5.
- Commit: "Add delete_to_trash, restore_from_trash, fetch_trash convenience methods".

**7. `synology-api::album_write`: create album (UNVERIFIED)**

- Files: `core/synology-api/src/album_write.rs` (new).
- Candidate shape: `api=SYNO.Foto(Team).Browse.Album, method=create,
  name=<string>` returning the new album's server-assigned id in `data`.
  UNVERIFIED, same probe discipline as Task 4.
- Function: `pub async fn create_album(transport: &Transport, sid: &str, space: Space, name: &str, version: u32) -> Result<Album, CoreError>;`
- TDD: mock test red/green, then the real-NAS probe sub-step (a disposable
  test album, created then noted for manual cleanup since Phase 2a has no
  delete-album feature), recording the confirmed shape into
  `phase0-probe-results.md`.
- Commit: "Add create_album to synology-api, verified against the NAS".

**8. `PhotosCore::create_album` facade + trash album reconciliation**

- Files: `core/photoscore/src/lib.rs`.
- `pub async fn create_album(&self, space: Space, name: String) -> Result<Album, CoreError>;`
  local-first-then-confirm like `move_assets`: on server success, upserts
  the returned `Album` (with its real `server_id`) into persistence.
- Also implements the trash-album reconciliation promised in section 5.2:
  if `ensure_trash_album` had previously created a local-only placeholder
  (`is_local_only = 1`), the next successful `create_album` call for the
  fixed trash-album name reconciles it (replaces the negative placeholder
  id with the server's real id, sets `is_local_only = 0`) rather than
  creating a second album. Add a dedicated
  `pub async fn ensure_trash_album_synced(&self, space: Space) -> Result<Album, CoreError>;`
  that Swift calls once after login/crawl to trigger this reconciliation
  eagerly instead of waiting for the user's first delete.
- TDD: mock test proving a local-only trash album gets its id replaced (not
  duplicated) once the server call succeeds; a second test proving that if
  the server call fails (network error), the local-only album keeps working
  for local trash operations (asset still moves into it locally) but stays
  `is_local_only = 1` for a later retry, i.e. delete-to-trash degrades
  gracefully to "recoverable locally, not yet mirrored as a real NAS album"
  rather than failing the whole delete.
- Commit: "Add create_album facade and trash album server reconciliation".

**9. Swift: `PhotosCoreClient` additions for move/album/trash**

- Files: `app/SynologyPhotos/CoreBridge/PhotosCoreClient.swift`.
- Thin async wrappers matching the new facade methods (`moveAssets`,
  `deleteToTrash`, `restoreFromTrash`, `fetchTrash`, `createAlbum`), same
  actor-isolated style as the existing Phase 1 methods.
- TDD: extend the existing `PhotosCoreClientTests.swift` / `FakePhotosCore.swift`
  fake with these methods (the fake already exists for Phase 1's surface;
  Phase 2a adds the new call signatures to it) and assert the client
  forwards calls and propagates errors unchanged.
- Commit: "Add move, trash, and album methods to PhotosCoreClient".

**10. Swift: second-backup acknowledgment gate**

- Files: `app/SynologyPhotos/Session/SecondBackupAck.swift` (new),
  `app/SynologyPhotosTests/SecondBackupAckTests.swift` (new).
- A small persisted flag (UserDefaults, keyed per signed-in username so
  switching accounts does not silently inherit another account's
  acknowledgment) with a single method:
  `func requireAcknowledgment(presenting: () async -> Bool) async -> Bool`,
  which only shows the one-time sheet if the flag is unset for this
  username, and returns true immediately (no UI) once it has been set.
- The acknowledgment text itself (drafted in this task, no dashes): asks the
  user to confirm an independent second backup of their photos exists
  before their first destructive action in the app, matching design
  section 6, risk 6.
- TDD: unit test proving the flag is per-username, proving a declined
  acknowledgment does not set the flag (so it is asked again next time),
  and proving an accepted acknowledgment persists and short-circuits future
  calls without presenting UI again.
- Commit: "Add one-time second-backup acknowledgment gate".

**11. Swift: delete confirm sheet wired to `deleteToTrash`**

- Files: `app/SynologyPhotos/Grid/DeleteConfirmView.swift` (new),
  `app/SynologyPhotos/Grid/PhotoGridController.swift` (add a delete
  action/menu item on selection).
- Flow: selection with 1+ assets exposes a delete action (menu item, delete
  key, or toolbar button) which first calls `SecondBackupAck` (Task 10),
  then shows a confirm sheet naming the count of assets and stating plainly
  that they move to the app's trash and can be restored, then on confirm
  calls `deleteToTrash`, then removes the assets from the current grid's
  visible window (a local UI removal, not a claim the server call already
  ran again; the facade call already completed by the time this happens).
- TDD: XCUITest or a controller-level unit test (matching the existing
  `PhotoGridControllerTests.swift` style) proving the confirm sheet appears
  before any core call, that cancel makes zero core calls, and that confirm
  calls `deleteToTrash` with exactly the selected ids.
- Commit: "Add delete confirmation flow to the photo grid".

**12. Swift: trash view + restore**

- Files: `app/SynologyPhotos/Trash/TrashView.swift` (new, reuses
  `PhotoGridView`/`WindowedDataSource` bound to `fetchTrash` instead of
  `fetchAssets`), `app/SynologyPhotos/Trash/TrashViewModel.swift` (new).
- A dedicated tab/section (not just a filter toggle on the main grid, to
  keep "this view is destructive-adjacent" visually distinct) listing
  trashed assets with a "restore" action per selection, wired to
  `restoreFromTrash`. No permanent-delete UI element exists here yet (that
  is explicitly Task 17, gated).
- TDD: view-model unit test proving restore calls `restoreFromTrash` with
  the selected ids and that the trash list refreshes (item disappears from
  trash view) only after a confirmed server response, matching constraint 3.
- Commit: "Add trash view with restore".

**13. Swift: album list + create + add-to-album UI**

- Files: `app/SynologyPhotos/Albums/AlbumListView.swift` (new),
  `app/SynologyPhotos/Albums/AlbumDetailView.swift` (new, reuses the grid
  components bound to `fetchAlbumMembers`... — see note below),
  `app/SynologyPhotos/Albums/CreateAlbumSheet.swift` (new).
- Note: `fetch_album_members` was added to `persistence` in Task 3 but not
  yet exposed on the `PhotosCore` facade; this task adds
  `pub fn fetch_album_members(&self, space: Space, album_id: i64, offset: u32, limit: u32) -> Result<Vec<Asset>, CoreError>;`
  to the facade (local read, no network, same pattern as `fetch_assets`) as
  its first step, with a unit test mirroring the existing
  `fetch_assets_and_albums_return_upserted_rows...` test.
- `AlbumListView` lists albums from `fetchAlbums` (already exists from
  Phase 1, currently unused by any UI since Phase 1 was read-only browse
  with no album screen), excluding the trash album (`is_trash`) from this
  list — trash has its own dedicated view (Task 12).
- "Add selected photos to album" action from the main grid's selection menu
  (alongside the delete action added in Task 11), presenting an album
  picker (existing albums plus a "new album" option invoking
  `CreateAlbumSheet`), calling `moveAssets` with `MoveTarget.album`.
- TDD: view-model tests proving the trash album never appears in the picker
  list, and that add-to-album calls `moveAssets` with the right target.
- Commit: "Add album list, create, and add-to-album UI".

**14. Delta reconciliation picks up server-side album/trash changes**

- Files: `core/sync-engine/src/delta.rs`.
- The existing `(id, server_version)` delta reconciler (Phase 1) already
  detects new/changed/deleted items by version; Phase 2a's writes bump the
  same version field server-side (any write should cause DSM to report a
  new `server_version` on next list, per the Phase 1 delta design), so no
  new reconciliation logic is needed for detecting a change happened. What
  Phase 2a's delta pass does need: when reconciling a changed item, also
  re-fetch its `additional` album-membership data (if a cheap way to get it
  exists via `Browse.Item` `additional=["album"]` or similar) and update
  `album_members` to match, so the local mirror doesn't drift when the same
  NAS is also managed from the Synology Photos mobile app or web UI
  concurrently.
- UNVERIFIED: whether `Browse.Item` exposes album membership as an
  `additional` field at all; if it does not, this task documents that
  limitation instead (album membership drift from concurrent external
  edits is a known, accepted gap, not silently pretended-away) and the
  reconciler is left as-is.
- TDD: if the field exists, a mock test proving a changed item's album
  membership is updated in `album_members` on reconcile; if it does not
  exist, a comment documenting the limitation plus no code change, and a
  note added to this plan's "open questions" outcome, not silently dropped.
- Commit: "Reconcile album membership drift on delta pass" (or, if the
  field does not exist: "Document album membership reconciliation gap").

### Phase 2b — favorites, search, gated permanent-delete

**15. `synology-api::favorite`: set favorite/rating (UNVERIFIED)**

- Files: `core/synology-api/src/favorite.rs` (new).
- Candidate shape (feasibility research confirms `set_item_favorite` /
  `set_item_rating` exist on a Python wrapper against `Browse.Item`, method
  name likely `set`): `api=SYNO.Foto(Team).Browse.Item, method=set,
  id=<asset_id>, favorite=<bool>, rating=<0..5>`. UNVERIFIED exact param
  names/whether favorite and rating are one call or two.
- Function:
  ```rust
  pub async fn set_favorite(transport: &Transport, sid: &str, space: Space, asset_id: i64, favorite: bool, version: u32) -> Result<(), CoreError>;
  pub async fn set_rating(transport: &Transport, sid: &str, space: Space, asset_id: i64, rating: u8, version: u32) -> Result<(), CoreError>;
  ```
- Steps: same TDD-then-probe discipline as Task 4/7. Reject (return an
  error before making the call, no network) a `rating` outside 0..5 at the
  Rust layer rather than sending it and hoping the NAS validates.
- Commit: "Add set_favorite and set_rating to synology-api, verified against the NAS".

**16. `PhotosCore::set_favorite`/`set_rating` with re-read-after-write**

- Files: `core/photoscore/src/lib.rs`.
- ```rust
  pub async fn set_favorite(&self, space: Space, asset_id: i64, favorite: bool) -> Result<Asset, CoreError>;
  pub async fn set_rating(&self, space: Space, asset_id: i64, rating: u8) -> Result<Asset, CoreError>;
  ```
  Both: call the API write, and on success, re-fetch that single item from
  the NAS (`Browse.Item` `method=list` with an `id` filter if supported, or
  a targeted `method=get`; whichever the existing `list_items` path
  supports — reuse it rather than adding a new browse call if a single-id
  list works) and persist the server's own returned state, not the value
  the caller passed in, then return the updated local `Asset`. This is the
  literal "metadata-only writes, re-read after write" rule from the design,
  applied concretely: the local `favorite`/`rating` columns are only ever
  set from a confirmed server read, never from the optimistic request value.
- TDD: mock test where the write succeeds but the re-read returns a
  different value than requested (simulating the NAS clamping or rejecting
  part of the request) and asserts the persisted local value matches the
  re-read, not the request.
- Commit: "Add set_favorite and set_rating to PhotosCore with re-read-after-write".

**17. Delete-semantics gate check-in: decide Phase 2b's permanent-delete path**

- Files: this plan document (edit in place, no code).
- Reads Task 1's recorded verdict. Two branches, chosen explicitly here
  before Task 18/19 are touched:
  - **Recoverable (soft delete confirmed):** Tasks 18 and 19 proceed as
    written below.
  - **Not recoverable (hard delete, or ambiguous/unable to determine):**
    Tasks 18 and 19 are replaced by a single task, "empty trash stays
    disabled": the "empty trash" UI action (if built at all) is relabeled
    to state plainly that permanent delete is disabled on this NAS, and no
    call to the real delete endpoint is ever added to the codebase. Update
    this plan's Task 18/19 headers to strike them and record which branch
    was taken, with the date and the verdict reference.
- This task cannot be completed until Task 1 has a real (non-"pending")
  verdict recorded. Do not guess or proceed past this gate speculatively.
- Commit: "Record delete-semantics gate decision for Phase 2b" (edits this
  plan file only; no application code in this commit).

**18. `synology-api::permanent_delete` (ONLY if Task 17 selects the
recoverable branch; UNVERIFIED)**

- Files: `core/synology-api/src/permanent_delete.rs` (new).
- Candidate shape from the probe doc's own procedure notes: `api=
  SYNO.Foto(Team).Browse.Item, method=delete, id=[<id>,...]` — this is
  exactly the call Task 1 already issued manually to determine the verdict,
  so its real shape is already captured verbatim in
  `phase0-probe-results.md` by the time this task starts; use that captured
  shape, not a fresh guess.
- Function: `pub async fn permanent_delete(transport: &Transport, sid: &str, space: Space, asset_ids: &[i64], version: u32) -> Result<(), CoreError>;`
- TDD: mock test red/green as usual. No further real-NAS probe needed for
  the shape (Task 1 already captured it); a confirmation-only real-NAS run
  against one more disposable throwaway asset is still done here to prove
  the code path matches the manual probe exactly, recorded as a one-line
  addendum to the probe doc.
- Commit: "Add permanent_delete to synology-api, matching the verified probe shape".

**19. `PhotosCore::empty_trash` (ONLY if Task 17 selects the recoverable
branch)**

- Files: `core/photoscore/src/lib.rs`.
- `pub async fn empty_trash(&self, space: Space, asset_ids: Vec<i64>) -> Result<(), CoreError>;`
  Only ever called on assets already `in_trash = 1` (the facade asserts
  this locally and returns `CoreError::WriteRefused` for any id not
  currently in the trash album, so the permanent-delete call can never be
  reached on an asset that skipped the trash step, closing off any UI bug
  that tries to call it directly on a non-trashed asset).
- On server confirm, removes the row from `assets` and `album_members`
  entirely (not just flips a flag) since it is genuinely gone from the NAS
  per the confirmed-recoverable verdict.
- Swift: `app/SynologyPhotos/Trash/TrashView.swift` gains an "empty trash"
  action requiring a second, separately worded confirmation (distinct
  copy from the move-to-trash confirm in Task 11, stating plainly this
  step cannot be undone even though the earlier move-to-trash step could
  be), reusing the `SecondBackupAck` gate's underlying pattern but not
  reusing its one-time flag (this confirmation is per-action, always
  shown, never skipped after the first time, precisely because it is the
  one truly irreversible action in the app).
- TDD: facade test proving `empty_trash` on a non-trashed id returns
  `WriteRefused` without any network call; a mock test proving success
  removes the row entirely; a Swift-side test proving the confirm copy is
  shown every time (never suppressed by a persisted flag).
- Commit: "Add empty_trash with WriteRefused guard for non-trashed assets".

**20. `synology-api::search` (UNVERIFIED)**

- Files: `core/synology-api/src/search.rs` (new).
- Candidate shape (feasibility research confirms `SYNO.Foto.Search.Search`,
  methods `list_item`/`count_item`, plus `SYNO.Foto.Search.Filter.list` for
  discovering filterable facets): `api=SYNO.Foto(Team).Search.Search,
  method=list_item, keyword=<text>, ...` — exact filter param names for
  date range and media kind UNVERIFIED.
- Function:
  ```rust
  pub async fn search_items(transport: &Transport, sid: &str, space: Space, query: &SearchQuery, offset: u32, limit: u32, version: u32) -> Result<Vec<Asset>, CoreError>;
  ```
- Steps: TDD-then-probe as usual. Additionally, this task's probe step
  specifically checks whether `SYNO.Foto.Search.Filter.list` (or any other
  discovered API) exposes a people/faces facet. Record the finding either
  way into `phase0-probe-results.md`:
  - If people/faces search exists: note the API/method/param shape for a
    follow-up task (not required to ship in this pass; can be added as
    Task 20a if time allows, using the same pattern).
  - If it does not exist (or is Shared-Space-only, or requires a paid
    add-on): record it plainly as a documented known limitation, and the
    Swift search UI (Task 22) omits a people filter entirely rather than
    showing one that silently does nothing.
- Commit: "Add search_items to synology-api, verified against the NAS".

**21. `PhotosCore::search` facade + local fallback**

- Files: `core/photoscore/src/lib.rs`.
- `pub async fn search(&self, query: SearchQuery, offset: u32, limit: u32) -> Result<Vec<Asset>, CoreError>;`
- Design choice made explicit here: search runs against the **local SQLite
  mirror** first (using the new `idx_assets_space_filename`/
  `idx_assets_space_favorite` indices and the existing date index), not the
  network `search_items` call, for the fields the local mirror already has
  (filename substring, date range, media kind, favorite). This keeps search
  instant and off the network for the common case and matches the app's
  existing "grid reads local, never blocks on NAS latency" principle. The
  network `search_items` call from Task 20 is reserved for fields the local
  mirror cannot answer (if/when people/faces search is added later) rather
  than being the primary path for Phase 2b's shipped filters.
- TDD: unit tests for each filter dimension (filename substring, date
  range, media kind, favorite_only) against a seeded local store, proving
  correct rows and windowing, space-scoping, and that an all-`None` query
  is rejected or documented as equivalent to `fetch_assets` (decide and
  test one specific behavior, not left ambiguous).
- Commit: "Add local-first search to PhotosCore".

**22. Swift: search bar UI**

- Files: `app/SynologyPhotos/Search/SearchBarView.swift` (new),
  `app/SynologyPhotos/Search/SearchViewModel.swift` (new).
- A search field plus filter chips (date range, media kind, favorites)
  above the main grid, debounced (matching the existing debounce principle
  from the design's data-flow section) so typing does not fire a query per
  keystroke, wired to the local-first `search` facade method.
- If Task 20 recorded people/faces as unavailable: this task adds a single
  disabled/absent state, not a broken control, per the design's
  requirement that a missing capability is a documented limitation, not a
  silent drop.
- TDD: view-model test proving debounce, proving each filter chip maps to
  the right `SearchQuery` field, and proving the missing-people-search
  state renders as documented-absent rather than a dead button (if
  applicable per Task 20's finding).
- Commit: "Add search bar with debounced local-first filtering".

### Cross-cutting close-out

**23. LAN end-to-end run of the full Phase 2 surface against the real NAS**

- Manual run (not a unit test): login, crawl, create an album, move a photo
  into it, delete a photo to trash, restore it, favorite a photo, rate a
  photo, search by filename and by date range, and (only if Task 17 went
  the recoverable branch) empty the trash on one disposable asset. Record
  any surprises into `phase0-probe-results.md`.
- Commit: none (this is a verification pass; any fixes it surfaces get
  their own commits against the specific task they correct).

**24. Security and safety audit of the Phase 2 write surface**

- Per CLAUDE.md's mandatory security scan rule for backend API changes:
  spawn a review pass (adversarial/skeptic review or `/ultrareview`,
  matching the project's solo-dev adjustment) specifically checking:
  - Every new write fails closed on an unexpected response (grep for every
    new `synology-api` write function and confirm no `unwrap`/`expect` on
    the decoded response, matching the existing `browse.rs` tolerant
    pattern).
  - `empty_trash` (if built) truly cannot be reached on a non-trashed asset
    (Task 19's `WriteRefused` guard) and its confirm copy cannot be
    suppressed.
  - The second-backup acknowledgment cannot be bypassed by any code path
    that calls `deleteToTrash` directly without going through the gate
    (audit every call site of `deleteToTrash`/`moveAssets` in the Swift
    app, not just the one added in Task 11).
  - No new call reintroduces `danger_accept_invalid_certs` or otherwise
    weakens the TLS trust contract from the Phase 0/1 interface contract
    section 2.6 / the `allow_untrusted_tls` escape hatch's documented
    constraints.
  - Confirm the destructive-action safety tests promised in the design's
    testing section (delete only ever moves to trash; writes fail closed
    on unexpected responses) are actually present and green, not merely
    described.
- Commit: fixes from the audit land as their own small commits against the
  specific issue found, referencing which audit item they close.

---

## 7. Testing summary (mapped to the design's four types)

- **Core unit + API-contract tests:** every new `synology-api` module
  (Tasks 4, 7, 15, 18, 20) gets mock-server red/green tests before its
  real-NAS probe step, matching the existing `*_mock.rs` pattern
  (`auth_mock.rs`, `browse_mock.rs`, etc.).
- **Destructive-action safety tests:** Task 5's "failure leaves local DB
  unchanged" test, Task 19's `WriteRefused` guard test, and Task 24's audit
  are the concrete instances of the design's blanket safety-test
  requirement for this phase.
- **UI / e2e tests:** Task 11's delete-confirm flow test, Task 12's restore
  test, Task 22's search debounce test; a new XCUITest analogous to the
  existing `PhotosCoreLinkSmokeUITests.swift` covering the delete-confirm-
  to-trash-to-restore round trip end to end is recommended in Task 23's
  manual pass and should be captured as an automated test immediately
  after if the manual run finds it stable.
- **Soak/chaos:** not newly introduced by Phase 2a/2b (no new long-running
  background process); Phase 2a's writes ride the existing delta
  reconciler, which already has Phase 1 soak coverage.

## 8. Self-review

**Placeholders.** Every task has concrete file paths, function signatures,
and a specific TDD step. Every UNVERIFIED wire shape is flagged inline and
paired with an explicit probe sub-step in the same task rather than being
deferred to an unnamed "later verification" task — the probe is the second
half of the same task, not a separate backlog item. No task says "figure out
the details later" without naming exactly what detail and how it gets
resolved (mock-first TDD, then a recorded real-NAS capture).

**Spec coverage against the design's Phase 2 scope.** Design section 2 and
section 4 (phasing) list: safe delete (trash-move) — Tasks 1, 5, 6, 11;
albums list/view (already done in Phase 1) + organize via move — Tasks 3, 7,
8, 13; background delta sync already exists — Task 14 extends it rather than
rebuilding it; real permanent-delete gated on Phase 0's probe — Tasks 1, 17,
18, 19; favorites/ratings metadata-only re-read-after-write — Tasks 15, 16;
search/filter by date/filename/metadata with people/faces as a documented
limitation if absent — Tasks 20, 21, 22. Every named Phase 2 deliverable in
the design has a task. Nothing in Phase 3 (non-destructive editing) or
Phase 4 (cross-platform, QuickConnect) leaked into this plan.

**Safety-invariant coverage.** Invariant 1 (originals immutable) is a Phase 3
concern but nothing in this plan mutates an original file; every write here
is metadata (favorite/rating), membership (album/trash), or a full-object
move, never a byte-level edit. Invariant 2 (delete = trash-move first, gated
permanent-delete second, writes fail closed) is Tasks 1, 4-6, 11, 12, 17-19
and constraint 1/3 in section 4. Invariant 3 (confirmation + one-time
second-backup acknowledgment on the first destructive action) is Tasks 10
and 11, with Task 19 adding a stronger, non-suppressible confirmation for
the one truly irreversible action. Invariant 4 (never touch iCloud/phone) is
constraint 4 in section 4 and is structurally satisfied: no task introduces
a new network destination.

**Known gaps surfaced by this review (see open questions below).** The exact
DSM API method name for move (Task 4) and for search (Task 20) are
genuinely unknown until probed; this plan treats that as expected and
budgeted for (a probe sub-step in the task itself), not a defect in the
plan. The people/faces search capability is unknown; Task 20 handles either
outcome explicitly. The trash album's exact display name is left to Task 1's
implementation step rather than fixed here since it is cosmetic and low
risk to decide later, but it should be decided before Task 2 needs to
reference a fixed string in test fixtures.

## 9. Open questions for the user (before implementation starts)

1. **Trash album name.** What should the app-owned trash album be called on
   the NAS (visible to the user if they browse Synology Photos directly on
   another device)? Suggested default: "App Trash". Needs a decision before
   Task 2's test fixtures hardcode a name.
2. **Rating scale confirmation.** The design and feasibility research both
   assume a 0 to 5 star rating matching Synology Photos' own UI, but this is
   unverified. If the real NAS uses a different scale (e.g. 0 to 1 thumbs,
   or no rating concept at all, only favorite), Task 15/16 need to adjust;
   worth confirming by checking the Synology Photos web UI's own rating
   control before Task 15 starts, to avoid a wasted probe cycle.
3. **Delete-semantics probe (Task 1) has not been run yet.** This entire
   plan's Phase 2b permanent-delete branch (Tasks 17-19) is unresolved until
   it runs. Recommend running Task 1 first, in parallel with Phase 2a
   Tasks 2-3, so the verdict is ready well before Task 17.
4. **Album membership reconciliation on delta sync (Task 14) depends on an
   unverified `Browse.Item` capability.** If `additional=["album"]` (or
   similar) does not exist, concurrent external edits (via the Synology
   Photos mobile app or web UI while this app is also managing albums) can
   drift the local album view out of sync between crawls. Worth deciding
   now whether that gap is acceptable for v1 or whether it should force a
   more frequent reconcile cadence as a mitigation; currently the plan
   documents it as an accepted gap pending the probe result.
5. **Second-backup acknowledgment wording and trigger scope.** Task 10
   drafts the acknowledgment text as part of implementation rather than
   this plan fixing it verbatim; if there is specific language wanted
   (mentioning Hyper Backup by name, or a specific backup solution already
   in place), that should be supplied before Task 10 rather than left to
   whoever implements it to guess.
