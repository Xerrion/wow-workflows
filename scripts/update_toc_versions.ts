#!/usr/bin/env bun
///////////////////////////////////////////////////////////////////////////////
// update_toc_versions.ts
// Fetches latest WoW interface versions from Blizzard's CDN and updates
// ## Interface directives in .toc files.
//
// Usage:  bun scripts/update_toc_versions.ts [--flavor FLAVOR]...
// Env:    None required (all config via CLI args)
///////////////////////////////////////////////////////////////////////////////

import { readdir, stat } from "node:fs/promises";
import { join, relative } from "node:path";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
const CDN_BASE = "https://us.version.battle.net/v2/products";
const MAX_RETRIES = 5;
const RETRY_DELAY = 2;
const VALID_FLAVORS = ["retail", "classic", "vanilla", "tbc"] as const;
const DEFAULT_EXCLUDE_DIRS = ["Libs"];

type Flavor = (typeof VALID_FLAVORS)[number];

const FLAVOR_PRODUCT: Record<Flavor, string> = {
  retail: "wow",
  classic: "wow_classic",
  vanilla: "wow_classic_era",
  tbc: "wow_anniversary",
};

// ---------------------------------------------------------------------------
// Version cache - avoid fetching the same CDN product twice
// ---------------------------------------------------------------------------
const VERSION_CACHE = new Map<string, string>();

// ---------------------------------------------------------------------------
// sleep - Promise-based delay
// ---------------------------------------------------------------------------
function sleep(seconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, seconds * 1000));
}

// ---------------------------------------------------------------------------
// versionToFlavor - Map an interface version number to its flavor name
//
// Args: ver = interface version string (e.g. "120001", "50502", "11503")
// Returns: flavor name ("retail", "classic", "vanilla", "tbc",
//          "cata", "wrath", or "unknown")
// ---------------------------------------------------------------------------
function versionToFlavor(ver: string): string {
  if (!/^[0-9]+$/.test(ver)) return "unknown";
  const num = Number.parseInt(ver, 10);

  if (num >= 100000) return "retail";
  if (num >= 50000) return "classic";
  if (num >= 40000) return "cata";
  if (num >= 30000) return "wrath";
  if (num >= 20000) return "tbc";
  if (num >= 10000) return "vanilla";
  return "unknown";
}

// ---------------------------------------------------------------------------
// usage - Print help text and exit
// ---------------------------------------------------------------------------
function usage(): void {
  console.log(`Usage: bun scripts/update_toc_versions.ts [OPTIONS]

Fetches latest WoW interface versions from Blizzard's CDN and updates
## Interface directives in .toc files.

Options:
  --flavor FLAVOR       Flavor to update (can be specified multiple times)
                        Valid: retail, classic, vanilla, tbc
                        Default: all flavors
  --path DIR            Directory to search for .toc files (default: current directory)
  --exclude-dir DIR     Directory to exclude from TOC search (can be specified
                        multiple times). Default: Libs
  --dry-run             Show what would change without modifying files
  --help                Show this help message

Examples:
  bun scripts/update_toc_versions.ts
  bun scripts/update_toc_versions.ts --flavor retail --flavor classic
  bun scripts/update_toc_versions.ts --path /path/to/addons
  bun scripts/update_toc_versions.ts --exclude-dir Libs --exclude-dir vendor`);
  process.exit(0);
}

// ---------------------------------------------------------------------------
// fetchVersion - Fetch interface version for a CDN product
//
// Args: product = CDN product name (e.g. "wow", "wow_classic")
// Returns: interface version number string (e.g. "120005")
// ---------------------------------------------------------------------------
async function fetchVersion(product: string): Promise<string> {
  // Return cached result if available
  const cached = VERSION_CACHE.get(product);
  if (cached !== undefined) return cached;

  const url = `${CDN_BASE}/${product}/versions`;
  let response = "";

  for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
    try {
      const res = await fetch(url, {
        signal: AbortSignal.timeout(30_000),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      response = await res.text();
      break;
    } catch {
      if (attempt < MAX_RETRIES) {
        console.error(
          `  Attempt ${attempt}/${MAX_RETRIES} failed, retrying in ${RETRY_DELAY}s...`,
        );
        await sleep(RETRY_DELAY);
      }
    }
  }

  if (!response) {
    console.error(
      `ERROR: Failed to fetch version for ${product} after ${MAX_RETRIES} attempts`,
    );
    process.exit(1);
  }

  // Parse header row to find VersionsName column index dynamically.
  // Header fields have type suffixes (e.g. "VersionsName!STRING:0") which we strip.
  const lines = response.split("\n").filter((l) => l.trim() !== "");
  if (lines.length === 0) {
    console.error(`ERROR: Empty CDN response for ${product}`);
    process.exit(1);
  }

  const headerFields = lines[0].split("|");
  let colIndex = -1;
  for (let i = 0; i < headerFields.length; i++) {
    const name = headerFields[i].replace(/!.*/, "");
    if (name === "VersionsName") {
      colIndex = i;
      break;
    }
  }

  if (colIndex === -1) {
    console.error(
      `ERROR: VersionsName column not found in CDN response header for ${product}`,
    );
    process.exit(1);
  }

  // Find US region row and extract VersionsName value
  let versionsName = "";
  for (let i = 1; i < lines.length; i++) {
    const fields = lines[i].split("|");
    if (fields[0] === "us") {
      versionsName = fields[colIndex] ?? "";
      break;
    }
  }

  if (!versionsName) {
    console.error(`ERROR: Could not parse US region version for ${product}`);
    process.exit(1);
  }

  // Strip build number: "12.0.1.66337" -> "12.0.1"
  const parts = versionsName.split(".");
  if (parts.length < 3) {
    console.error(
      `ERROR: Unexpected version format '${versionsName}' for ${product}`,
    );
    process.exit(1);
  }
  const gameVersion = `${parts[0]}.${parts[1]}.${parts[2]}`;

  // Convert to interface version: "12.0.1" -> "120001"
  const major = parseInt(parts[0], 10);
  const minor = parseInt(parts[1], 10);
  const patch = parseInt(parts[2], 10);
  const interfaceVersion = `${major}${String(minor).padStart(2, "0")}${String(patch).padStart(2, "0")}`;

  // Validate interface version is a 5-6 digit number
  if (!/^[0-9]{5,6}$/.test(interfaceVersion)) {
    console.error(
      `ERROR: Invalid interface version '${interfaceVersion}' for ${product} (expected 5-6 digits)`,
    );
    process.exit(1);
  }

  // Cache the result
  VERSION_CACHE.set(product, interfaceVersion);

  return interfaceVersion;
}

// ---------------------------------------------------------------------------
// findTocFiles - Discover .toc files recursively, excluding specified dirs
//
// Args: searchDir = directory to search
//       excludeDirs = directories to exclude
// Returns: list of toc file paths
// ---------------------------------------------------------------------------
async function findTocFiles(
  searchDir: string,
  excludeDirs: string[],
): Promise<string[]> {
  const results: string[] = [];

  async function walk(dir: string): Promise<void> {
    const entries = await readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      const fullPath = join(dir, entry.name);
      if (entry.isDirectory()) {
        if (!excludeDirs.includes(entry.name)) {
          await walk(fullPath);
        }
      } else if (entry.isFile() && entry.name.endsWith(".toc")) {
        results.push(fullPath);
      }
    }
  }

  await walk(searchDir);
  return results;
}

// ---------------------------------------------------------------------------
// updateTocDirective - Update a single directive in a TOC file if it exists,
//                      preserving comma-separated multi-value lists.
//
// Args: content   = current file content
//       suffix    = directive suffix (empty for "## Interface:", or e.g. "-Mists")
//       version   = new version value
//       targetFlavor = used to identify which value to replace in bare
//                      "## Interface:" multi-value lists
//       dryRun    = whether to skip actual writes
// Returns: { content, message, changed }
// ---------------------------------------------------------------------------
interface DirectiveResult {
  content: string;
  message: string | null;
  changed: boolean;
}

function updateTocDirective(
  content: string,
  suffix: string,
  version: string,
  targetFlavor: string,
  dryRun: boolean,
): DirectiveResult {
  const directive = `## Interface${suffix}:`;
  const directivePattern = new RegExp(
    `^## Interface${escapeRegex(suffix)}: (.*)$`,
    "m",
  );
  const match = content.match(directivePattern);

  // Guard: directive must exist in the file
  if (!match) {
    return { content, message: null, changed: false };
  }

  const currentValue = match[1];

  // Parse comma-separated values, trimming whitespace and \r
  const values = currentValue
    .split(",")
    .map((v) => v.replace(/[\s\r]/g, ""))
    .filter((v) => v !== "");

  // Guard: if the new version already appears anywhere, nothing to do
  if (values.includes(version)) {
    return {
      content,
      message: `  ${directive} ${currentValue} (unchanged)`,
      changed: false,
    };
  }

  // Build the replacement value list
  let newValues: string[];
  let replaced = false;

  if (suffix !== "") {
    // Flavor-specific directive: all values share the same flavor.
    // Replace only the FIRST value, keep the rest as-is.
    newValues = [version, ...values.slice(1)];
    replaced = true;
  } else {
    // Bare "## Interface:" - values can belong to different flavors.
    // Replace only the FIRST value whose flavor matches targetFlavor.
    newValues = [];
    for (const val of values) {
      if (!replaced && versionToFlavor(val) === targetFlavor) {
        newValues.push(version);
        replaced = true;
      } else {
        newValues.push(val);
      }
    }
  }

  // Guard: if no value was replaced, don't modify the file
  if (!replaced) {
    return { content, message: null, changed: false };
  }

  // Reconstruct the replacement line with consistent ", " spacing
  const joined = newValues.join(", ");
  const replacement = `## Interface${suffix}: ${joined}`;
  const newContent = content.replace(directivePattern, replacement);

  if (dryRun) {
    return {
      content,
      message: `  ${directive} ${currentValue} -> ${joined} (dry-run)`,
      changed: true,
    };
  }

  return {
    content: newContent,
    message: `  ${directive} ${currentValue} -> ${joined}`,
    changed: true,
  };
}

// ---------------------------------------------------------------------------
// escapeRegex - Escape special regex characters in a string
// ---------------------------------------------------------------------------
function escapeRegex(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// ---------------------------------------------------------------------------
// hasDirective - Check if a file content contains a specific directive
// ---------------------------------------------------------------------------
function hasDirective(content: string, suffix: string): boolean {
  const pattern = new RegExp(`^## Interface${escapeRegex(suffix)}: `, "m");
  return pattern.test(content);
}

// ---------------------------------------------------------------------------
// updateTocFile - Update all relevant directives in a single TOC file
//
// Returns true if any directive was actually updated (file changed)
// ---------------------------------------------------------------------------
async function updateTocFile(
  tocFile: string,
  initialContent: string,
  flavors: Flavor[],
  flavorVersions: Record<string, string>,
  hasClassicFlavor: boolean,
  dryRun: boolean,
): Promise<boolean> {
  let content = initialContent;
  let fileChanged = false;

  function applyDirective(
    suffix: string,
    version: string,
    targetFlavor: string,
  ): void {
    const result = updateTocDirective(
      content,
      suffix,
      version,
      targetFlavor,
      dryRun,
    );
    if (result.message) console.log(result.message);
    if (result.changed) {
      content = result.content;
      fileChanged = true;
    }
  }

  for (const flavor of flavors) {
    const version = flavorVersions[flavor];
    if (!version) continue;

    switch (flavor) {
      case "retail":
        applyDirective("", version, "retail");
        break;
      case "classic":
        applyDirective("-Mists", version, "classic");
        applyDirective("-Classic", version, "classic");
        break;
      case "vanilla":
        applyDirective("-Vanilla", version, "vanilla");
        if (!hasClassicFlavor) {
          applyDirective("-Classic", version, "vanilla");
        }
        break;
      case "tbc":
        applyDirective("-BCC", version, "tbc");
        applyDirective("-TBC", version, "tbc");
        break;
    }
  }

  // Write file only if content actually changed (not dry-run)
  if (fileChanged && !dryRun) {
    await Bun.write(tocFile, content);
  }

  return fileChanged;
}

// ---------------------------------------------------------------------------
// fileHasRelevantDirectives - Check if a TOC file has any directives we care about
// ---------------------------------------------------------------------------
function fileHasRelevantDirectives(
  content: string,
  flavors: Flavor[],
  hasClassicFlavor: boolean,
): boolean {
  for (const flavor of flavors) {
    switch (flavor) {
      case "retail":
        if (hasDirective(content, "")) return true;
        break;
      case "classic":
        if (hasDirective(content, "-Mists")) return true;
        if (hasDirective(content, "-Classic")) return true;
        break;
      case "vanilla":
        if (hasDirective(content, "-Vanilla")) return true;
        if (!hasClassicFlavor && hasDirective(content, "-Classic")) return true;
        break;
      case "tbc":
        if (hasDirective(content, "-BCC")) return true;
        if (hasDirective(content, "-TBC")) return true;
        break;
    }
  }
  return false;
}

// ---------------------------------------------------------------------------
// parseArgs - Parse CLI arguments
// ---------------------------------------------------------------------------
interface ParsedArgs {
  flavors: Flavor[];
  searchDir: string;
  excludeDirs: string[];
  dryRun: boolean;
}

function parseArgs(argv: string[]): ParsedArgs {
  const flavors: Flavor[] = [];
  const excludeDirs: string[] = [];
  let excludeDirsSpecified = false;
  let searchDir = ".";
  let dryRun = false;

  let i = 0;
  while (i < argv.length) {
    const arg = argv[i];

    switch (arg) {
      case "--help":
        usage();
        break; // unreachable, usage() is `never`

      case "--flavor": {
        const value = argv[i + 1];
        if (!value) {
          console.error("ERROR: --flavor requires a value");
          process.exit(1);
        }
        if (!VALID_FLAVORS.includes(value as Flavor)) {
          console.error(
            `ERROR: Invalid flavor '${value}'. Valid: ${VALID_FLAVORS.join(" ")}`,
          );
          process.exit(1);
        }
        flavors.push(value as Flavor);
        i += 2;
        break;
      }

      case "--exclude-dir": {
        const value = argv[i + 1];
        if (!value) {
          console.error("ERROR: --exclude-dir requires a value");
          process.exit(1);
        }
        excludeDirs.push(value);
        excludeDirsSpecified = true;
        i += 2;
        break;
      }

      case "--path": {
        const value = argv[i + 1];
        if (!value) {
          console.error("ERROR: --path requires a value");
          process.exit(1);
        }
        // Directory existence checked later in main
        searchDir = value;
        i += 2;
        break;
      }

      case "--dry-run":
        dryRun = true;
        i += 1;
        break;

      default:
        console.error(`ERROR: Unknown argument '${arg}'`);
        console.error("Run with --help for usage");
        process.exit(1);
    }
  }

  return {
    flavors: flavors.length > 0 ? flavors : [...VALID_FLAVORS],
    searchDir,
    excludeDirs: excludeDirsSpecified ? excludeDirs : [...DEFAULT_EXCLUDE_DIRS],
    dryRun,
  };
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));

  // Validate search directory
  try {
    const dirStat = await stat(args.searchDir);
    if (!dirStat.isDirectory()) {
      console.error(`ERROR: '${args.searchDir}' is not a directory`);
      process.exit(1);
    }
  } catch {
    console.error(`ERROR: '${args.searchDir}' is not a directory`);
    process.exit(1);
  }

  // Track whether classic/vanilla flavors are active (for priority logic)
  const hasClassicFlavor = args.flavors.includes("classic");

  // -- Fetch versions -------------------------------------------------------
  const flavorVersions: Record<string, string> = {};

  for (const flavor of args.flavors) {
    const product = FLAVOR_PRODUCT[flavor];
    console.log(`Fetching ${flavor} (${product}) version from Blizzard CDN...`);
    const version = await fetchVersion(product);
    flavorVersions[flavor] = version;
    console.log(`  -> ${version}`);
  }

  // -- Find and update TOC files --------------------------------------------
  const tocFiles = await findTocFiles(args.searchDir, args.excludeDirs);

  if (tocFiles.length === 0) {
    console.log("No .toc files found");
    process.exit(0);
  }

  let updatedCount = 0;

  for (const tocFile of tocFiles) {
    const content = await Bun.file(tocFile).text();

    // Check if this file has any relevant directives before printing header
    if (!fileHasRelevantDirectives(content, args.flavors, hasClassicFlavor)) {
      continue;
    }

    console.log(`Updating ${tocFile}:`);
    const changed = await updateTocFile(
      tocFile,
      content,
      args.flavors,
      flavorVersions,
      hasClassicFlavor,
      args.dryRun,
    );
    if (changed) {
      updatedCount++;
    }
  }

  // -- Summary --------------------------------------------------------------
  if (updatedCount > 0) {
    console.log(`Updated ${updatedCount} file(s)`);
  } else {
    console.log("No changes needed - all versions are current");
  }

  process.exit(0);
}

main();
