use std::process::Command;

use anyhow::{bail, Context, Result};
use clap::Parser;

/// Generate a clean changelog from git log between two tags.
///
/// Strips release commits, attribution lines, and dash-only lines.
/// Optionally strips squash-merge sub-commits and linkifies PR refs.
#[derive(Parser, Debug)]
#[command(
    name = "generate-changelog",
    about = "Generates a clean changelog from git log between two tags.\n\
             Strips release commits, attribution lines, and dash-only lines."
)]
pub struct Cli {
    /// Output file path.
    #[arg(long, default_value = ".release/CHANGELOG.md")]
    pub output: String,

    /// GitHub repository in OWNER/REPO format.
    /// Defaults to $GITHUB_REPOSITORY env var.
    #[arg(long, value_name = "OWNER/REPO")]
    pub repo: Option<String>,

    /// Tag to generate changelog for.
    /// Defaults to $TAG_NAME env var, then `git describe --tags --abbrev=0`.
    #[arg(long, value_name = "TAG")]
    pub tag: Option<String>,

    /// Drop entire commit body, keep only subject lines.
    #[arg(long)]
    pub no_sub_commits: bool,

    /// Convert (#123) references to GitHub PR markdown links.
    #[arg(long)]
    pub linkify_prs: bool,

    /// Print to stdout instead of writing file.
    #[arg(long)]
    pub dry_run: bool,
}

impl Cli {
    /// Parse CLI arguments via clap. Wraps `Parser::parse()` for ergonomics.
    pub fn parse_args() -> Self {
        Self::parse()
    }

    /// Resolve the GitHub repository: CLI flag > GITHUB_REPOSITORY env > error.
    pub fn resolve_repo(&self) -> Result<String> {
        if let Some(repo) = &self.repo {
            return Ok(repo.clone());
        }

        if let Ok(repo) = std::env::var("GITHUB_REPOSITORY") {
            if !repo.is_empty() {
                return Ok(repo);
            }
        }

        bail!("GITHUB_REPOSITORY must be set or --repo provided")
    }

    /// Resolve the current tag: CLI flag > TAG_NAME env > `git describe` > error.
    pub fn resolve_tag(&self) -> Result<String> {
        if let Some(tag) = &self.tag {
            return Ok(tag.clone());
        }

        if let Ok(tag) = std::env::var("TAG_NAME") {
            if !tag.is_empty() {
                return Ok(tag);
            }
        }

        let output = Command::new("git")
            .args(["describe", "--tags", "--abbrev=0"])
            .output()
            .context("failed to run git describe")?;

        if !output.status.success() {
            bail!("no tag found via --tag, $TAG_NAME, or git describe");
        }

        let tag = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if tag.is_empty() {
            bail!("git describe returned empty tag");
        }

        Ok(tag)
    }
}
