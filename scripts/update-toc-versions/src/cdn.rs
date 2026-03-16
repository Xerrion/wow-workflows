use std::collections::HashMap;

use anyhow::{bail, Result};

/// Blizzard CDN base URL for product version info.
const CDN_BASE: &str = "https://us.version.battle.net/v2/products";

/// Maximum number of fetch attempts before giving up.
const MAX_RETRIES: u32 = 5;

/// Delay in seconds between retry attempts.
const RETRY_DELAY_SECS: u64 = 2;

/// Fetch the interface version for a CDN product, using a cache to avoid
/// duplicate network requests for the same product.
///
/// Returns a 5-6 digit interface version string (e.g. "120001").
pub fn fetch_version(
    client: &reqwest::blocking::Client,
    product: &str,
    cache: &mut HashMap<String, String>,
) -> Result<String> {
    // Return cached result if available
    if let Some(cached) = cache.get(product) {
        return Ok(cached.clone());
    }

    let url = format!("{CDN_BASE}/{product}/versions");
    let response = fetch_with_retries(client, &url, product)?;

    let interface_version = parse_cdn_response(&response, product)?;
    validate_interface_version(&interface_version, product)?;

    cache.insert(product.to_string(), interface_version.clone());
    Ok(interface_version)
}

/// Attempt an HTTP GET with retries, printing retry messages to stderr.
fn fetch_with_retries(
    client: &reqwest::blocking::Client,
    url: &str,
    product: &str,
) -> Result<String> {
    let mut last_err = None;

    for attempt in 1..=MAX_RETRIES {
        match client
            .get(url)
            .send()
            .and_then(|r| r.error_for_status())
            .and_then(|r| r.text())
        {
            Ok(body) if !body.is_empty() => return Ok(body),
            Ok(_) => {
                last_err = Some("empty response".to_string());
            }
            Err(e) => {
                last_err = Some(e.to_string());
            }
        }

        if attempt < MAX_RETRIES {
            eprintln!(
                "  Attempt {attempt}/{MAX_RETRIES} failed, retrying in {RETRY_DELAY_SECS}s..."
            );
            std::thread::sleep(std::time::Duration::from_secs(RETRY_DELAY_SECS));
        }
    }

    bail!(
        "Failed to fetch version for {product} after {MAX_RETRIES} attempts: {}",
        last_err.unwrap_or_default()
    )
}

/// Parse the pipe-delimited CDN response to extract an interface version.
///
/// The response format is:
/// - Line 1: header row with typed column names (e.g. `VersionsName!STRING:0`)
/// - Remaining lines: data rows, first column is region (we want `us`)
fn parse_cdn_response(response: &str, product: &str) -> Result<String> {
    let mut lines = response.lines();

    // Parse header to find VersionsName column index
    let header = match lines.next() {
        Some(h) if !h.is_empty() => h,
        _ => bail!("VersionsName column not found in CDN response header for {product}"),
    };

    let col_index = header.split('|').position(|col| {
        let name = col.split('!').next().unwrap_or("");
        name == "VersionsName"
    });

    let col_index = match col_index {
        Some(i) => i,
        None => bail!("VersionsName column not found in CDN response header for {product}"),
    };

    // Find the US region row and extract the version
    let versions_name = lines
        .filter_map(|line| {
            let fields: Vec<&str> = line.split('|').collect();
            if fields.first().map(|f| f.trim()) == Some("us") {
                fields.get(col_index).map(|v| v.trim().to_string())
            } else {
                None
            }
        })
        .next();

    let versions_name = match versions_name {
        Some(v) if !v.is_empty() => v,
        _ => bail!("Could not parse US region version for {product}"),
    };

    // Strip build number: "12.0.1.66337" -> extract major.minor.patch
    let parts: Vec<&str> = versions_name.split('.').collect();
    if parts.len() < 3 {
        bail!("Could not parse US region version for {product}");
    }

    // Convert to interface version: "12.0.1" -> "120001"
    let major: u32 = parts[0].parse().unwrap_or(0);
    let minor: u32 = parts[1].parse().unwrap_or(0);
    let patch: u32 = parts[2].parse().unwrap_or(0);
    let interface_version = format!("{}", major * 10000 + minor * 100 + patch);

    Ok(interface_version)
}

/// Validate that an interface version is a 5-6 digit number.
fn validate_interface_version(version: &str, product: &str) -> Result<()> {
    let len = version.len();
    if !(5..=6).contains(&len) || !version.chars().all(|c| c.is_ascii_digit()) {
        bail!("Invalid interface version '{version}' for {product} (expected 5-6 digits)");
    }
    Ok(())
}
