# Synology Web API versions

Single source of truth for every Synology Web API this app depends on. When
a DSM release changes a version range, this is the one file to check first.

The advertised ranges below were captured against the user's real NAS on
2026-07-25. Photos live in the Personal space (`SYNO.Foto.*`); the Shared
space (`SYNO.FotoTeam.*`) is not enabled on this account and returns error
801, so the `FotoTeam` ranges could not be captured live and are inferred to
mirror their `Foto` counterparts.

DSM version: `<fill in>` (to be provided; captured 2026-07-25).

## How versions are chosen at runtime

The app almost never hardcodes the version it sends. On each connection it
probes `SYNO.API.Info` once (`probe_capabilities`), caches the advertised
`[minVersion, maxVersion]` window per API, then calls
`pin_version(&caps, api, desired)` before each request.
`pin_version` clamps `desired` into the advertised window
(`core/synology-api/src/info.rs:98`), so a "version the app sends" value
listed below is really "the version the app asks for, clamped into whatever
range this NAS advertises". Two APIs (`SYNO.API.Auth`, `SYNO.API.Info`) and
one facet call (`SYNO.Foto.Search.Filter`) send a hardcoded literal instead,
noted in the table.

## API table

| API | Advertised range on this NAS (min..max) | Version the app sends | Where the version is pinned or sent |
| --- | --- | --- | --- |
| SYNO.API.Auth | 1..7 | 3 (hardcoded) | `core/synology-api/src/auth.rs:69` `AUTH_VERSION`, used by `login`/`logout` |
| SYNO.API.Info | 1 (issued at `/webapi/query.cgi`) | 1 (hardcoded) | `core/synology-api/src/info.rs:32` `INFO_VERSION`, used by `probe_capabilities` |
| SYNO.Foto.Browse.Item | 1..7 | 1 (pinned, desired 1) | `core/photoscore/src/lib.rs:722` `page_source_for`; also `discovery_call_context` at `lib.rs:750` for `fetch_assets_for` |
| SYNO.FotoTeam.Browse.Item | 1..7 | 1 (pinned, desired 1) | `core/photoscore/src/lib.rs:723` fallback in `page_source_for` |
| SYNO.Foto.Thumbnail | 1..2 | 2 (pinned, desired 2) | `core/photoscore/src/lib.rs:528` `thumbnail` |
| SYNO.FotoTeam.Thumbnail | not captured (Shared space returns 801; mirrors 1..2) | 2 (pinned, desired 2) | `core/photoscore/src/lib.rs:528` `thumbnail` (Shared branch, api name from `namespace.rs:19`) |
| SYNO.Foto.Download | 1..2 | 2 (pinned, desired 2) | `core/photoscore/src/lib.rs:575` `download_original` |
| SYNO.FotoTeam.Download | not captured (Shared space returns 801; mirrors 1..2) | 2 (pinned, desired 2) | `core/photoscore/src/lib.rs:575` `download_original` (Shared branch, api name from `namespace.rs:26`) |
| SYNO.Foto.Search.Search | advertised (method `list_item`, param `keyword`) | 1 (pinned, desired 1) | `core/photoscore/src/lib.rs:433`/`455` via `discovery_call_context` (`lib.rs:750`); request built in `core/synology-api/src/browse.rs:506` |
| SYNO.Foto.Search.Filter | advertised (method `list`; v1..4 return identical payload) | 1 (hardcoded) | `core/synology-api/src/search_filter.rs:141`, called by `fetch_search_facets` at `core/photoscore/src/lib.rs:470` |
| SYNO.Foto.Browse.Person | advertised | 1 (pinned, desired 1) | `core/photoscore/src/lib.rs:366` via `discovery_call_context`; request in `core/synology-api/src/discovery.rs:165` |
| SYNO.Foto.Browse.Geocoding | advertised | 1 (pinned, desired 1) | `core/photoscore/src/lib.rs:373` via `discovery_call_context`; `discovery.rs:196` |
| SYNO.Foto.Browse.Concept | advertised | 1 (pinned, desired 1) | `core/photoscore/src/lib.rs:384` via `discovery_call_context`; `discovery.rs:259` |
| SYNO.Foto.Browse.GeneralTag | advertised | 1 (pinned, desired 1) | `core/photoscore/src/lib.rs:391` via `discovery_call_context`; `discovery.rs:228` |
| SYNO.Foto.Browse.Album | advertised | 1 (pinned, desired 1) | `core/photoscore/src/lib.rs:355` via `discovery_call_context`; `list_albums` in `core/synology-api/src/browse.rs` |
| SYNO.Foto.Favorite | advertised, but not used | not sent | No dedicated Favorite list API is called. `SYNO.Foto.Favorite.Item` returns error 102 on this NAS, so favorites are fetched by filtering `Browse.Item` with `favorite=true` (`CollectionFilter::Favorites`, `core/synology-api/src/browse.rs:103`) |
| SYNO.Core.RecycleBin | 1..1 (config/status only; does NOT list files) | not sent yet | No shipped code path sends it; the delete feature that will use it is in progress and out of scope for this doc |

## Gotchas

- State-reading calls (browse, thumbnail, download) require the
  `X-SYNO-TOKEN` header (the SynoToken), not just `_sid`. Without it DSM
  returns error 119. The `syno_token` is threaded through every such call.
- Thumbnails and downloads key on `additional.thumbnail.unit_id` (and the
  `cache_key`), NOT the browse item `id`. Sending the item id returns an
  HTML error page instead of bytes. The browse list must request
  `additional=["thumbnail","resolution"]` to receive `cache_key`/`unit_id`.
- `SYNO.API.Info` is issued at `/webapi/query.cgi`, while every other
  `SYNO.*` call in this app dispatches through `/webapi/entry.cgi`.
- Some Core APIs advertise `requestFormat: JSON` and attach extra fields to
  the Info response. The capability decoder ignores unknown fields rather
  than failing, so those extras are harmless.
- `SYNO.Foto.Search.Search list_item` only genuinely narrows on
  `start_time`/`end_time`. Every other candidate facet param (camera,
  aperture, geocoding, media type, person, tag, folder, and JSON-blob
  `condition`/`filter`) was probed and found to be silently ignored.

## How to update when a DSM release changes a version range

1. Re-probe `SYNO.API.Info` against the NAS (any `real_nas` integration
   test, or a throwaway example, prints the advertised windows). Update the
   "Advertised range" column and the `DSM version` line above.
2. If a range only shrank or grew, there is usually nothing to change in
   code: `pin_version` clamps the desired version into whatever window the
   probe now reports, so the app self-heals. For example, if
   `SYNO.Foto.Thumbnail` ever dropped to max 1, the desired-2 pin would
   clamp to 1 automatically.
3. If a required method is renamed, removed, or a NEW method/param is
   needed, that is a code change at the cited call site (the "Where the
   version is pinned or sent" column), not just a doc edit. `pin_version`
   fails closed with `CapabilityUnavailable` when an API disappears from the
   advertised set entirely, which surfaces the break rather than silently
   sending a request to an endpoint that no longer exists.
4. Keep the small API list in `app/SynologyPhotos/About/AboutInfo.swift`
   (`knownApiVersions`) in sync with the "Version the app sends" column, so
   the About window and this doc never disagree.
