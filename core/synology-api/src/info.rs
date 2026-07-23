//! SYNO.API.Info: capability probe and version pinning.
//!
//! The Synology Photos Web API is unofficial and undocumented, and its
//! per-endpoint version range drifts across DSM releases. `SYNO.API.Info`
//! is the one endpoint Synology does document: given `query=all` (or a
//! comma-separated API list) it reports every advertised `SYNO.*` API
//! along with the `minVersion`/`maxVersion` window DSM currently supports
//! for it. This module probes that once per connection and lets callers
//! pin the version they actually send on every subsequent request to a
//! value guaranteed to be inside the advertised window, instead of
//! hardcoding a version number and hoping it still exists.
//!
//! Verified against the real NAS (documentation/phase0-probe-results.md):
//! the Info query itself is issued at `/webapi/query.cgi`, a sibling of the
//! shared `/webapi/entry.cgi` dispatcher every other API in this crate
//! goes through (NOT `/photo/webapi/query.cgi`). Confirmed live version
//! ranges: `SYNO.API.Auth`, `SYNO.Foto.Browse.Item` and
//! `SYNO.FotoTeam.Browse.Item` all advertise 1..7, while
//! `SYNO.Foto.Thumbnail` tops out at 2 - proof the ranges genuinely differ
//! per API and must never be assumed uniform.

use crate::envelope::decode_envelope;
use crate::transport::Transport;
use models::{ApiCapability, CoreError};
use serde::Deserialize;
use std::collections::HashMap;

/// SYNO.API.Info is issued at its own CGI endpoint, not the shared
/// `/webapi/entry.cgi` dispatcher (verified against the real NAS).
const INFO_PATH: &str = "/webapi/query.cgi";
const INFO_API: &str = "SYNO.API.Info";
const INFO_VERSION: &str = "1";

/// One entry in the `SYNO.API.Info` response map. Decoded tolerantly:
/// DSM attaches extra fields (`requestFormat` and others observed live)
/// that this crate has no use for, so unknown fields are ignored rather
/// than treated as a decode failure.
#[derive(Debug, Deserialize)]
struct CapEntry {
    path: String,
    #[serde(rename = "minVersion")]
    min_version: u32,
    #[serde(rename = "maxVersion")]
    max_version: u32,
}

/// Probe `SYNO.API.Info` with `query=all` and return every advertised API
/// as an `ApiCapability`. Order is not guaranteed (backed by a JSON object);
/// callers that need a stable order should sort.
pub async fn probe_capabilities(transport: &Transport) -> Result<Vec<ApiCapability>, CoreError> {
    transport.throttle().await;

    let query: Vec<(&str, &str)> = vec![
        ("api", INFO_API),
        ("version", INFO_VERSION),
        ("method", "query"),
        ("query", "all"),
    ];

    let url = format!("{}{}", transport.base_url(), INFO_PATH);
    let response = transport
        .client()
        .get(&url)
        .query(&query)
        .send()
        .await
        .map_err(|e| CoreError::Network { message: format!("capability probe request failed: {e}") })?;
    let body = response
        .text()
        .await
        .map_err(|e| CoreError::Network { message: format!("failed to read capability probe body: {e}") })?;

    let map: HashMap<String, CapEntry> = decode_envelope(&body)?;
    Ok(map
        .into_iter()
        .map(|(name, entry)| ApiCapability {
            name,
            path: entry.path,
            min_version: entry.min_version,
            max_version: entry.max_version,
        })
        .collect())
}

/// Pin the version to request for `api` given the caller's `desired`
/// version and the window a capability probe discovered.
///
/// `desired` is clamped into `[min_version, max_version]`: a desired
/// version above the advertised max is pulled down to the max (this is
/// the case that matters most in practice - `SYNO.Foto.Thumbnail` caps at
/// 2 on the real NAS while every other Foto API goes to 7), and a desired
/// version below the advertised min is pushed up to the min.
///
/// FAIL CLOSED: if `api` is absent from `caps` entirely, this returns
/// `CoreError::CapabilityUnavailable` rather than silently picking a
/// default version and risking a request against an endpoint that does
/// not exist on this DSM.
pub fn pin_version(caps: &[ApiCapability], api: &str, desired: u32) -> Result<u32, CoreError> {
    let cap = caps
        .iter()
        .find(|c| c.name == api)
        .ok_or_else(|| CoreError::CapabilityUnavailable { api: api.to_string() })?;
    Ok(desired.clamp(cap.min_version, cap.max_version))
}
