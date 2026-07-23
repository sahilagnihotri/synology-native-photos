# Phase 0 Probe Results

Empirical facts captured against the real Synology NAS. Sections owned by Author A
(user setup, delete-semantics procedure) and Author B (API.Info, login/2FA, browse
and media shapes, cert DER) are appended to this one file. Treat the API facts as a
moving target: version-guard and decode tolerantly against what is recorded here.

Read-only invariant: nothing in Phase 0/1 adds delete or edit code to the core. The
only deletion in Phase 0 is the manual, human-run probe below on a throwaway asset,
performed to characterize semantics. Its verdict informs future phases only.

## Verified facts (captured 2026-07-23, real NAS over Tailscale)

Connection: reachable over Tailscale at 100.87.107.5, ~5ms latency. DSM ports 5000
(http) and 5001 (https) both open.

API path prefix (IMPORTANT correction): all Photos/Auth APIs are served at
`/webapi/entry.cgi`, NOT `/photo/webapi/...` as some community docs assume. The
`SYNO.API.Info` query at `/webapi/query.cgi` reports `path: "entry.cgi"` for every
API. The core must build request URLs as `https://<host>:5001/webapi/entry.cgi`.

Capability probe (no login required), verified version ranges on this DSM:

| API | path | minVersion | maxVersion |
|-----|------|-----------|-----------|
| SYNO.API.Auth | entry.cgi | 1 | 7 |
| SYNO.Foto.Browse.Item | entry.cgi | 1 | 7 |
| SYNO.Foto.Thumbnail | entry.cgi | 1 | 2 |
| SYNO.FotoTeam.Browse.Item | entry.cgi | 1 | 7 |

`SYNO.Foto.Thumbnail` maxVersion is 2 (lower than the browse APIs at 7); pin thumbnail
requests to a version within 1..2. Version-pin every request to a value inside the
range the capability probe returns at runtime; do not hardcode blindly.

TLS / cert: the DSM presents a valid Let's Encrypt cert (issuer C=US O=Let's Encrypt
CN=YE2) with subject CN=`agnihotri.synology.me`, valid 2026-07-07 to 2026-10-05. It is
NOT self-signed. Consequence: connecting by the DDNS name `agnihotri.synology.me`
validates TLS cleanly with no pinning needed. Connecting by the raw Tailscale IP
100.87.107.5 causes a hostname mismatch (cert CN is the DNS name). Cert-trust design:
prefer the DNS name where the public cert validates; when using the Tailscale IP,
handle the hostname-mismatch deliberately (pin the leaf cert or connect by a name that
matches), and never globally disable TLS validation.

Library state: confirmed populated and live (the Synology Photos mobile app backs up to
this NAS and works), so Browse.Item will return real assets once authenticated.

## Dedicated DSM Photos-only user

Purpose: the app authenticates as a dedicated, least-privilege DSM account that can
reach Synology Photos and nothing else. This isolates the app's blast radius and
keeps 2FA scoped to an account we control.

Setup steps (DSM 7.x, Control Panel):

1. Control Panel -> User & Group -> User -> Create.
   - Name: photosclient
   - Description: "Dedicated account for synology-native-photos client"
   - Password: strong, stored only in the developer's password manager (never in the repo).
2. User Groups: assign to users only. Do NOT add to administrators.
3. Permissions (shared folders): grant Read only to the /photo shared folder for
   Phase 0/1 (read-only). No access to other shares.
4. Applications: deny all applications except Synology Photos. This blocks File
   Station, DSM desktop, etc.
5. Two-factor authentication: enroll 2FA for this account. Mandatory: the login flow
   handles OTP from the first login task. Record the enrolled method.
6. Quota/speed: leave defaults; not relevant to a read client.

Verification (human, before Phase 1 login work):
- Log in to DSM web as photosclient: only Synology Photos should be reachable.
- Confirm a 2FA prompt appears at login (proves OTP path is exercised).

Notes:
- The account's SID is stored by the app in the macOS Keychain (KeychainSID), never
  on disk in plaintext, never in the repo.
- The project decision is 2FA stays ON.

## Delete-semantics probe procedure

Purpose: characterize what a Synology Photos API delete actually does (move to a
recycle bin / trash vs permanent unlink) BEFORE any delete feature is designed. This
is a one-time manual probe. No delete code is added to the core in Phase 0/1.

Preconditions:
- A throwaway image uploaded to Personal Space specifically for this probe.
- A captured, working SID + SynoToken from the login probe (Task 10).
- The throwaway asset's id, unit_id, and cache_key from a Browse.Item list.

Procedure (run by a human against the real NAS; record every response verbatim):

1. Confirm the asset is listed via SYNO.Foto.Browse.Item method=list; record id, unit_id, cache_key.
2. Observe the DSM Recycle Bin / trash state before delete (item count; SMB path if mounted).
3. Issue the delete call (manual curl, throwaway asset only). The exact API/method is
   UNVERIFIED here on purpose; record what the real NAS exposes. Candidate observed in
   the wild is SYNO.Foto.Browse.Item method=delete with an id array:
   ```
   curl -sk "https://<HOST>:5001/photo/webapi/entry.cgi" \
     --data-urlencode "api=SYNO.Foto.Browse.Item" \
     --data-urlencode "method=delete" \
     --data-urlencode "version=1" \
     --data-urlencode "id=[<THROWAWAY_ID>]" \
     --data-urlencode "_sid=<SID>" \
     -H "X-SYNO-TOKEN: <SYNO_TOKEN>"
   ```
   Record: HTTP status, success flag, any error.code.
4. Re-check state AFTER delete: still in Browse.Item list? in a trash location (API/album)?
   SMB file gone or moved to #recycle (path)? separate permanent-delete / empty-trash API?
5. If a trash location holds it, probe the permanent-delete step separately (still on the throwaway).

### Delete-semantics verdict (fill against real NAS)

| Field | Value |
|-------|-------|
| Date probed | pending |
| DSM version | pending |
| Delete API + method used | pending |
| Delete request version | pending |
| Response success/error.code | pending |
| After delete: still in Browse.Item list? | pending |
| After delete: appears in DSM trash/Recently Deleted? (API/album name) | pending |
| After delete: SMB file gone or moved to #recycle? (path) | pending |
| Separate permanent-delete / empty-trash API? (name+method) | pending |
| Verdict: trash-move then gated permanent-delete confirmed? | pending |
| Notes / surprises | pending |

Design implication (locked project invariant): whatever this probe finds, the future
delete feature will be trash-move first, then a gated permanent-delete, with writes
failing closed. Phase 0/1 ship NO delete UI and NO delete code in the core.
