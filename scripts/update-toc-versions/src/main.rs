mod cdn;
mod cli;
mod toc;

use std::collections::HashMap;

use anyhow::Result;

use cdn::fetch_version;
use cli::Cli;
use toc::{find_toc_files, has_relevant_directives, update_toc_file};

/// Map a flavor name to its Blizzard CDN product identifier.
fn flavor_to_product(flavor: &str) -> &'static str {
    match flavor {
        "retail" => "wow",
        "classic" => "wow_classic",
        "vanilla" => "wow_classic_era",
        "tbc" => "wow_anniversary",
        _ => unreachable!("invalid flavor: {flavor}"),
    }
}

fn run(cli: Cli) -> Result<()> {
    let flavors = cli.effective_flavors();
    let exclude_dirs = cli.effective_exclude_dirs();

    let has_classic_flavor = flavors.iter().any(|f| f == "classic");

    // -- Fetch versions from CDN ---------------------------------------------
    let mut version_cache: HashMap<String, String> = HashMap::new();
    let mut flavor_versions: HashMap<String, String> = HashMap::new();

    let client = reqwest::blocking::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(10))
        .timeout(std::time::Duration::from_secs(30))
        .build()?;

    for flavor in &flavors {
        let product = flavor_to_product(flavor);
        println!("Fetching {flavor} ({product}) version from Blizzard CDN...");

        let version = fetch_version(&client, product, &mut version_cache)?;
        println!("  -> {version}");
        flavor_versions.insert(flavor.clone(), version);
    }

    // -- Find and update TOC files -------------------------------------------
    let toc_files = find_toc_files(&cli.path, &exclude_dirs);

    if toc_files.is_empty() {
        println!("No .toc files found");
        return Ok(());
    }

    let mut updated_count: usize = 0;

    for toc_file in &toc_files {
        let content = std::fs::read_to_string(toc_file)?;

        if !has_relevant_directives(&content, &flavors, has_classic_flavor) {
            continue;
        }

        let display_path = toc_file.display();
        println!("Updating {display_path}:");

        let changed = update_toc_file(
            toc_file,
            &content,
            &flavors,
            &flavor_versions,
            has_classic_flavor,
            cli.dry_run,
        )?;

        if changed {
            updated_count += 1;
        }
    }

    // -- Summary -------------------------------------------------------------
    if updated_count > 0 {
        println!("Updated {updated_count} file(s)");
    } else {
        println!("No changes needed - all versions are current");
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
