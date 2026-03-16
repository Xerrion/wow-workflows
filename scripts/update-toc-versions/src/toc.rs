use std::collections::HashMap;
use std::path::{Path, PathBuf};

use anyhow::Result;
use regex::Regex;
use walkdir::WalkDir;

/// Map an interface version number to its flavor name.
///
/// Ranges:
/// - 100000+  -> "retail"
/// - 50000-99999 -> "classic"
/// - 40000-49999 -> "cata"
/// - 30000-39999 -> "wrath"
/// - 20000-29999 -> "tbc"
/// - 10000-19999 -> "vanilla"
/// - else -> "unknown"
fn version_to_flavor(version_str: &str) -> &'static str {
    let ver: u32 = version_str.parse().unwrap_or(0);
    match ver {
        v if v >= 100_000 => "retail",
        50_000..=99_999 => "classic",
        40_000..=49_999 => "cata",
        30_000..=39_999 => "wrath",
        20_000..=29_999 => "tbc",
        10_000..=19_999 => "vanilla",
        _ => "unknown",
    }
}

/// Discover .toc files recursively under `search_dir`, excluding any path
/// segments that match entries in `exclude_dirs`.
pub fn find_toc_files(search_dir: &str, exclude_dirs: &[String]) -> Vec<PathBuf> {
    WalkDir::new(search_dir)
        .into_iter()
        .filter_entry(|entry| {
            if entry.file_type().is_dir() {
                let dir_name = entry.file_name().to_string_lossy();
                !exclude_dirs.iter().any(|ex| dir_name == *ex)
            } else {
                true
            }
        })
        .filter_map(|entry| entry.ok())
        .filter(|entry| {
            entry.file_type().is_file()
                && entry
                    .path()
                    .extension()
                    .map(|ext| ext == "toc")
                    .unwrap_or(false)
        })
        .map(|entry| entry.into_path())
        .collect()
}

/// Check whether TOC file content contains any directives relevant to the active
/// flavors. Used to skip printing the file header for irrelevant files.
pub fn has_relevant_directives(
    content: &str,
    flavors: &[String],
    has_classic_flavor: bool,
) -> bool {
    for flavor in flavors {
        let starts = |prefix: &str| content.lines().any(|line| line.starts_with(prefix));
        let found = match flavor.as_str() {
            "retail" => starts("## Interface: "),
            "classic" => starts("## Interface-Mists: ") || starts("## Interface-Classic: "),
            "vanilla" => {
                starts("## Interface-Vanilla: ")
                    || (!has_classic_flavor && starts("## Interface-Classic: "))
            }
            "tbc" => starts("## Interface-BCC: ") || starts("## Interface-TBC: "),
            _ => false,
        };
        if found {
            return true;
        }
    }

    false
}

/// Update all relevant directives in a single TOC file for the given flavors.
///
/// Accepts the file content as a string to avoid re-reading from disk.
/// Returns `true` if any directive was actually modified.
pub fn update_toc_file(
    toc_file: &Path,
    content: &str,
    flavors: &[String],
    flavor_versions: &HashMap<String, String>,
    has_classic_flavor: bool,
    dry_run: bool,
) -> Result<bool> {
    let mut content = content.to_string();
    let mut file_changed = false;

    for flavor in flavors {
        let version = match flavor_versions.get(flavor.as_str()) {
            Some(v) => v,
            None => continue,
        };

        let directives = directives_for_flavor(flavor, has_classic_flavor);

        for (suffix, target_flavor) in directives {
            match update_toc_directive(&content, suffix, version, target_flavor, dry_run) {
                DirectiveResult::Updated(new_content) => {
                    content = new_content;
                    file_changed = true;
                }
                DirectiveResult::Unchanged | DirectiveResult::NotFound => {}
            }
        }
    }

    if file_changed && !dry_run {
        std::fs::write(toc_file, &content)?;
    }

    Ok(file_changed)
}

/// Return the list of (directive_suffix, target_flavor) pairs for a given
/// flavor, respecting the classic/vanilla priority logic.
fn directives_for_flavor(
    flavor: &str,
    has_classic_flavor: bool,
) -> Vec<(&'static str, &'static str)> {
    match flavor {
        "retail" => vec![("", "retail")],
        "classic" => vec![("-Mists", "classic"), ("-Classic", "classic")],
        "vanilla" => {
            let mut dirs = vec![("-Vanilla", "vanilla")];
            if !has_classic_flavor {
                dirs.push(("-Classic", "vanilla"));
            }
            dirs
        }
        "tbc" => vec![("-BCC", "tbc"), ("-TBC", "tbc")],
        _ => vec![],
    }
}

/// Result of attempting to update a single directive within file content.
enum DirectiveResult {
    /// Directive was found and updated. Contains the new file content.
    Updated(String),
    /// Directive exists but value is already current.
    Unchanged,
    /// Directive does not exist in the file.
    NotFound,
}

/// Update a single `## Interface{suffix}:` directive in file content.
///
/// For flavor-specific directives (non-empty suffix), replaces the first
/// comma-separated value. For bare `## Interface:`, replaces only the value
/// whose flavor matches `target_flavor`.
fn update_toc_directive(
    content: &str,
    suffix: &str,
    version: &str,
    target_flavor: &str,
    dry_run: bool,
) -> DirectiveResult {
    let directive = format!("## Interface{suffix}:");

    // Build regex to match the directive line
    let escaped_suffix = regex::escape(suffix);
    let pattern = format!(r"^## Interface{escaped_suffix}: (.+)$");
    let re = match Regex::new(&pattern) {
        Ok(r) => r,
        Err(_) => return DirectiveResult::NotFound,
    };

    // Find the first matching line
    let line_match = content.lines().find(|line| re.is_match(line));
    let matched_line = match line_match {
        Some(l) => l.to_string(),
        None => return DirectiveResult::NotFound,
    };

    // Extract the current value string (everything after the directive prefix)
    let current_value = match re.captures(&matched_line) {
        Some(caps) => caps.get(1).map(|m| m.as_str()).unwrap_or(""),
        None => return DirectiveResult::NotFound,
    };

    // Parse comma-separated values, trimming whitespace and \r
    let values: Vec<String> = current_value
        .split(',')
        .map(|v| v.trim().trim_matches('\r').to_string())
        .filter(|v| !v.is_empty())
        .collect();

    // If the new version already appears, nothing to do
    if values.iter().any(|v| v == version) {
        println!("  {directive} {current_value} (unchanged)");
        return DirectiveResult::Unchanged;
    }

    // Build replacement value list
    let (new_values, replaced) = if !suffix.is_empty() {
        // Flavor-specific: replace first value, keep rest
        let mut nv = vec![version.to_string()];
        nv.extend(values.into_iter().skip(1));
        (nv, true)
    } else {
        // Bare ## Interface: - replace first value matching target_flavor
        let mut nv = Vec::with_capacity(values.len());
        let mut did_replace = false;
        for val in &values {
            if !did_replace && version_to_flavor(val) == target_flavor {
                nv.push(version.to_string());
                did_replace = true;
            } else {
                nv.push(val.clone());
            }
        }
        (nv, did_replace)
    };

    if !replaced {
        return DirectiveResult::NotFound;
    }

    let joined = new_values.join(", ");

    if dry_run {
        println!("  {directive} {current_value} -> {joined} (dry-run)");
    } else {
        println!("  {directive} {current_value} -> {joined}");
    }

    // Replace the matched line in the content
    let replacement = format!("## Interface{suffix}: {joined}");
    let new_content = content.replacen(&matched_line, &replacement, 1);

    DirectiveResult::Updated(new_content)
}
