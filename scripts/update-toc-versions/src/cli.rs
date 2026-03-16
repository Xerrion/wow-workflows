use clap::Parser;

/// Valid flavor names accepted by the CLI.
const VALID_FLAVORS: &[&str] = &["retail", "classic", "vanilla", "tbc"];

/// Default directories excluded from TOC file search.
const DEFAULT_EXCLUDE_DIRS: &[&str] = &["Libs"];

/// Fetch latest WoW interface versions from Blizzard's CDN and update
/// ## Interface directives in .toc files.
#[derive(Parser, Debug)]
#[command(
    name = "update-toc-versions",
    about = "Fetches latest WoW interface versions from Blizzard's CDN and updates\n\
             ## Interface directives in .toc files."
)]
pub struct Cli {
    /// Flavor to update (can be specified multiple times).
    /// Valid: retail, classic, vanilla, tbc. Default: all flavors.
    #[arg(long = "flavor", value_name = "FLAVOR", value_parser = parse_flavor)]
    pub flavors: Vec<String>,

    /// Directory to search for .toc files (default: current directory).
    #[arg(long, default_value = ".")]
    pub path: String,

    /// Directory to exclude from TOC search (can be specified multiple times).
    /// Default: Libs.
    #[arg(long = "exclude-dir", value_name = "DIR")]
    pub exclude_dirs: Vec<String>,

    /// Show what would change without modifying files.
    #[arg(long)]
    pub dry_run: bool,
}

/// Validate that a flavor string is one of the accepted values.
fn parse_flavor(s: &str) -> Result<String, String> {
    if VALID_FLAVORS.contains(&s) {
        Ok(s.to_string())
    } else {
        Err(format!(
            "Invalid flavor '{s}'. Valid: {}",
            VALID_FLAVORS.join(", ")
        ))
    }
}

impl Cli {
    /// Parse CLI arguments via clap. Wraps `Parser::parse()` for ergonomics.
    pub fn parse_args() -> Self {
        Self::parse()
    }

    /// Return the effective flavor list - all flavors if none were specified.
    pub fn effective_flavors(&self) -> Vec<String> {
        if self.flavors.is_empty() {
            VALID_FLAVORS.iter().map(|s| (*s).to_string()).collect()
        } else {
            self.flavors.clone()
        }
    }

    /// Return the effective exclude-dir list - defaults to `["Libs"]` if none specified.
    pub fn effective_exclude_dirs(&self) -> Vec<String> {
        if self.exclude_dirs.is_empty() {
            DEFAULT_EXCLUDE_DIRS
                .iter()
                .map(|s| (*s).to_string())
                .collect()
        } else {
            self.exclude_dirs.clone()
        }
    }
}
