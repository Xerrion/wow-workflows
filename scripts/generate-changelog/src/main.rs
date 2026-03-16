mod cli;

use std::fs;
use std::process::Command;

use anyhow::{bail, Context, Result};
use regex::Regex;

use cli::Cli;

/// Run `git` with the given arguments and return trimmed stdout on success.
fn git(args: &[&str]) -> Result<String> {
    let output = Command::new("git")
        .args(args)
        .output()
        .with_context(|| format!("failed to run: git {}", args.join(" ")))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("git {} failed: {}", args.join(" "), stderr.trim());
    }

    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// Run `git` with the given arguments and return Ok(stdout) or Err on failure.
/// Unlike `git()`, this doesn't bail - used when failure is expected (e.g. no previous tag).
fn git_optional(args: &[&str]) -> Option<String> {
    let output = Command::new("git").args(args).output().ok()?;

    if !output.status.success() {
        return None;
    }

    let result = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if result.is_empty() {
        return None;
    }

    Some(result)
}

/// Resolve the previous tag before `current_tag`, if one exists.
fn resolve_previous_tag(current_tag: &str) -> Option<String> {
    let tag_ref = format!("{current_tag}^");
    git_optional(&["describe", "--tags", "--abbrev=0", &tag_ref])
}

/// Get the date of a tag in short ISO format (YYYY-MM-DD).
fn tag_date(tag: &str) -> Result<String> {
    git(&["log", "-1", "--format=%as", "--", tag]).context("failed to get tag date")
}

/// Get NUL-delimited commit records for the given range.
fn commit_records(range: &str) -> Result<String> {
    git(&["log", "--format=%s%n%b%x00", range]).context("failed to get git log")
}

/// Derive project name from "OWNER/REPO" format (e.g. "Xerrion/PhDamage" -> "PhDamage").
fn project_name(repo: &str) -> &str {
    repo.rsplit('/').next().unwrap_or(repo)
}

/// Check if a commit subject is a release commit.
///
/// Matches: "chore: release ..." and "chore(ANYTHING): release ..."
fn is_release_commit(subject: &str) -> bool {
    if let Some(rest) = subject.strip_prefix("chore") {
        if let Some(rest) = rest.strip_prefix(": release ") {
            return !rest.is_empty() || subject.ends_with("release ");
        }
        if let Some(rest) = rest.strip_prefix('(') {
            if let Some(after_paren) = rest.find(')') {
                let after = &rest[after_paren + 1..];
                return after.starts_with(": release ");
            }
        }
    }
    false
}

/// Build the full changelog content as a string.
fn build_changelog(
    repo: &str,
    current_tag: &str,
    previous_tag: Option<&str>,
    no_sub_commits: bool,
    linkify_prs: bool,
) -> Result<String> {
    let date = tag_date(current_tag)?;
    let name = project_name(repo);

    let attribution_re =
        Regex::new(r"(?i)^\s*(co-authored-by:|ultraworked\s+with)").expect("valid regex");
    let dash_only_re = Regex::new(r"^-+$").expect("valid regex");
    let pr_ref_re = Regex::new(r"\(#(\d+)\)").expect("valid regex");

    let linkify = |line: &str| -> String {
        if linkify_prs {
            pr_ref_re
                .replace_all(line, format!("[#$1](https://github.com/{repo}/pull/$1)"))
                .to_string()
        } else {
            line.to_string()
        }
    };

    let mut out = String::new();

    // -- Header --
    out.push_str(&format!("# {name}\n"));
    out.push('\n');
    out.push_str(&format!(
        "## [{current_tag}](https://github.com/{repo}/tree/{current_tag}) ({date})\n"
    ));

    if let Some(prev) = previous_tag {
        out.push_str(&format!(
            "[Full Changelog](https://github.com/{repo}/compare/{prev}...{current_tag})"
        ));
    } else {
        out.push_str(&format!(
            "[Full Changelog](https://github.com/{repo}/commits/{current_tag})"
        ));
    }

    out.push_str(&format!(
        " [Previous Releases](https://github.com/{repo}/releases)\n"
    ));
    out.push('\n');

    // -- Commit range --
    let range = match previous_tag {
        Some(prev) => format!("{prev}..{current_tag}"),
        None => current_tag.to_string(),
    };

    let log_output = commit_records(&range)?;

    // -- Process NUL-delimited records --
    for record in log_output.split('\0') {
        let record = record.trim_matches('\n');
        if record.is_empty() {
            continue;
        }

        let mut lines = record.lines();

        // Extract subject (first non-empty line)
        let subject = loop {
            match lines.next() {
                Some(line) if !line.is_empty() => break line,
                Some(_) => continue,
                None => break "",
            }
        };

        // Guard: skip records with no usable subject
        if subject.is_empty() {
            continue;
        }

        // Guard: skip release commits
        if is_release_commit(subject) {
            continue;
        }

        // Print subject as list item (with optional PR linkification)
        out.push_str(&format!("- {}\n", linkify(subject)));

        // Skip body entirely when --no-sub-commits is active
        if no_sub_commits {
            continue;
        }

        // Process remaining body lines
        for line in lines {
            // Skip attribution/metadata lines
            if attribution_re.is_match(line) {
                continue;
            }

            // Skip dash-only lines
            if dash_only_re.is_match(line) {
                continue;
            }

            // Skip empty lines
            if line.is_empty() {
                continue;
            }

            // Indent body lines by 4 spaces (with optional PR linkification)
            out.push_str(&format!("    {}\n", linkify(line)));
        }
    }

    // Trailing newline
    out.push('\n');

    Ok(out)
}

fn run(cli: Cli) -> Result<()> {
    let repo = cli.resolve_repo()?;

    // Validate owner/repo format
    if !repo.contains('/') || repo.split('/').count() != 2 {
        bail!("invalid repo format '{repo}'. Expected OWNER/REPO");
    }

    let current_tag = cli.resolve_tag()?;
    let previous_tag = resolve_previous_tag(&current_tag);

    let changelog = build_changelog(
        &repo,
        &current_tag,
        previous_tag.as_deref(),
        cli.no_sub_commits,
        cli.linkify_prs,
    )?;

    if cli.dry_run {
        print!("{changelog}");
    } else {
        if let Some(parent) = std::path::Path::new(&cli.output).parent() {
            if !parent.as_os_str().is_empty() {
                fs::create_dir_all(parent)
                    .with_context(|| format!("failed to create directory: {}", parent.display()))?;
            }
        }
        fs::write(&cli.output, &changelog)
            .with_context(|| format!("failed to write {}", cli.output))?;
        println!("Changelog written to {}", cli.output);
    }

    Ok(())
}

fn main() {
    let cli = Cli::parse_args();

    if let Err(err) = run(cli) {
        eprintln!("ERROR: {err:#}");
        std::process::exit(1);
    }
}
