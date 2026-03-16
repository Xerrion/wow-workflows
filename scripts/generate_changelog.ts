#!/usr/bin/env bun
///////////////////////////////////////////////////////////////////////////////
// generate_changelog.ts
// Generates a clean changelog for the BigWigsMods packager release pipeline.
// Strips release commits, attribution lines (Co-authored-by, Ultraworked with),
// and dash-only lines from the git log. Optionally strips squash-merge
// sub-commits and linkifies PR refs.
//
// Usage:  bun scripts/generate_changelog.ts [OPTIONS]
// Env:    TAG_NAME           - tag to generate changelog for (optional)
//         GITHUB_REPOSITORY  - owner/repo for links (auto-set in GitHub Actions)
///////////////////////////////////////////////////////////////////////////////

import { dirname } from "node:path";
import { mkdir } from "node:fs/promises";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
const REPO_PATTERN = /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/;
const RELEASE_COMMIT_PATTERN = /^chore(?:\(.*\))?: release /i;
const ATTRIBUTION_PATTERN =
  /^\s*(?:co-authored-by:|ultraworked\s+with)/i;
const DASH_ONLY_PATTERN = /^-+$/;
const PR_REF_PATTERN = /\(#(\d+)\)/g;

// ---------------------------------------------------------------------------
// die - Print error to stderr and exit
// ---------------------------------------------------------------------------
function die(message: string): never {
  console.error(`ERROR: ${message}`);
  process.exit(1);
}

// ---------------------------------------------------------------------------
// usage - Print help text and exit
// ---------------------------------------------------------------------------
function usage(): never {
  console.log(`Usage: bun scripts/generate_changelog.ts [OPTIONS]

Generates a clean changelog from git log between two tags.

Options:
  --output FILE         Output file path (default: .release/CHANGELOG.md)
  --repo OWNER/REPO     GitHub repository (default: $GITHUB_REPOSITORY)
  --tag TAG             Tag to generate changelog for (default: latest)
  --no-sub-commits      Strip squash-merge sub-commit lines from body
  --linkify-prs         Convert (#123) references to GitHub PR links
  --dry-run             Print to stdout instead of writing file
  --help                Show this help`);
  process.exit(0);
}

// ---------------------------------------------------------------------------
// git - Run a git command and return trimmed stdout
//
// Args: args = git subcommand arguments
// Returns: stdout text (trimmed)
// Throws: on non-zero exit code with descriptive error
// ---------------------------------------------------------------------------
async function git(...args: string[]): Promise<string> {
  const proc = Bun.spawn(["git", ...args], {
    stdout: "pipe",
    stderr: "pipe",
  });

  const stdout = await new Response(proc.stdout).text();
  const exitCode = await proc.exited;
  const stderr = await new Response(proc.stderr).text();

  if (exitCode !== 0) {
    // Include stderr output in error message for better debugging
    const errorMsg = stderr.trim() || `git ${args.join(" ")} exited with code ${exitCode}`;
    throw new Error(`git command failed: ${errorMsg}`);
  }

  return stdout.trim();
}

// ---------------------------------------------------------------------------
// gitRaw - Run a git command and return raw stdout (untrimmed)
//
// Same as git() but preserves NUL delimiters and whitespace.
// ---------------------------------------------------------------------------
async function gitRaw(...args: string[]): Promise<string> {
  const proc = Bun.spawn(["git", ...args], {
    stdout: "pipe",
    stderr: "pipe",
  });

  const stdout = await new Response(proc.stdout).text();
  const exitCode = await proc.exited;
  const stderr = await new Response(proc.stderr).text();

  if (exitCode !== 0) {
    // Include stderr output in error message for better debugging
    const errorMsg = stderr.trim() || `git ${args.join(" ")} exited with code ${exitCode}`;
    throw new Error(`git command failed: ${errorMsg}`);
  }

  return stdout;
}

// ---------------------------------------------------------------------------
// resolveCurrentTag - Determine the tag to generate changelog for
//
// Priority: CLI flag > TAG_NAME env > git describe
// Throws: if no valid tag can be resolved
// ---------------------------------------------------------------------------
async function resolveCurrentTag(cliTag: string): Promise<string> {
  // Early exit: CLI flag takes precedence
  if (cliTag && cliTag.trim() !== "") {
    return cliTag.trim();
  }

  // Early exit: environment variable fallback
  const envTag = process.env.TAG_NAME;
  if (envTag && envTag.trim() !== "") {
    return envTag.trim();
  }

  // Fallback: try git describe to find latest tag
  try {
    return await git("describe", "--tags", "--abbrev=0");
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    die("No tag specified and git describe failed. Use --tag or set TAG_NAME: " + errorMessage);
  }
}

// ---------------------------------------------------------------------------
// resolvePreviousTag - Find the tag before the current one
//
// Returns empty string if no previous tag exists (first release).
// Throws: if git describe fails unexpectedly (shouldn't happen for first release)
// ---------------------------------------------------------------------------
async function resolvePreviousTag(currentTag: string): Promise<string> {
  // Guard: reject null/undefined current tag
  if (currentTag == null || currentTag.trim() === "") {
    throw new Error("resolvePreviousTag requires a non-empty currentTag");
  }

  try {
    return await git("describe", "--tags", "--abbrev=0", `${currentTag}^`);
  } catch (error) {
    // Expected to fail for first release - return empty string gracefully
    if (error instanceof Error && error.message.includes("No tags found")) {
      return "";
    }
    // Re-throw unexpected errors
    throw error;
  }
}

// ---------------------------------------------------------------------------
// getTagDate - Get the short ISO date for a tag
//
// Args: tag = tag name to query
// Returns: short date string (e.g., "2024-01-15")
// Throws: if git command fails
// ---------------------------------------------------------------------------
async function getTagDate(tag: string): Promise<string> {
  // Input validation: reject empty or null tag
  if (tag == null || tag.trim() === "") {
    throw new Error("getTagDate requires a non-empty tag name");
  }

  return await git("log", "-1", `--format=%as`, "--", tag);
}

// ---------------------------------------------------------------------------
// isReleaseCommit - Check if a subject line is a release commit
//
// Matches: "chore: release ..." and "chore(*): release ..."
// ---------------------------------------------------------------------------
function isReleaseCommit(subject: string): boolean {
  return RELEASE_COMMIT_PATTERN.test(subject);
}

// ---------------------------------------------------------------------------
// isAttributionLine - Check if a line is a co-author or ultraworked attribution
// ---------------------------------------------------------------------------
function isAttributionLine(line: string): boolean {
  return ATTRIBUTION_PATTERN.test(line);
}

// ---------------------------------------------------------------------------
// isDashOnlyLine - Check if a line consists entirely of dashes
// ---------------------------------------------------------------------------
function isDashOnlyLine(line: string): boolean {
  return DASH_ONLY_PATTERN.test(line);
}

// ---------------------------------------------------------------------------
// linkifyPrRefs - Convert (#123) patterns into markdown PR links
//
// Args: text = line of text
//       repo = owner/repo string (validated at boundary)
// Returns: transformed line with PR references linkified
// Throws: if repo format is invalid (should be validated before calling)
// ---------------------------------------------------------------------------
function linkifyPrRefs(text: string, repo: string): string {
  return text.replace(
    PR_REF_PATTERN,
    (_, num) => `[#${num}](https://github.com/${repo}/pull/${num})`,
  );
}

// ---------------------------------------------------------------------------
// parseCommitRecord - Extract subject and body from a NUL-delimited record
//
// Args: record = raw commit record (subject\nbody)
// Returns: { subject, bodyLines } with subject as first non-empty line
// Throws: if record is null/undefined or empty after trimming
// ---------------------------------------------------------------------------
interface CommitRecord {
  subject: string;
  bodyLines: string[];
}

function parseCommitRecord(record: string): CommitRecord | null {
  // Early exit: reject null/undefined inputs
  if (record == null || record.trim() === "") {
    return null;
  }

  const lines = record.split("\n");

  // Find first non-empty line as subject
  let subjectIndex = -1;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].trim() !== "") {
      subjectIndex = i;
      break;
    }
  }

  // Early exit: no valid subject found
  if (subjectIndex === -1) {
    return null;
  }

  return {
    subject: lines[subjectIndex],
    bodyLines: lines.slice(subjectIndex + 1),
  };
}

// ---------------------------------------------------------------------------
// formatBodyLines - Filter and indent body lines
//
// Strips attribution lines, dash-only lines, and empty lines.
// Optionally linkifies PR references.
// Throws: if inputs are invalid
// ---------------------------------------------------------------------------
function formatBodyLines(
  bodyLines: string[],
  linkify: boolean,
  repo: string,
): string[] {
  const result: string[] = [];

  for (const line of bodyLines) {
    // Early exit: skip empty lines
    if (line == null || line.trim() === "") {
      continue;
    }

    // Skip attribution lines
    if (isAttributionLine(line)) {
      continue;
    }

    // Skip dash-only lines
    if (isDashOnlyLine(line)) {
      continue;
    }

    const formatted = linkify ? linkifyPrRefs(line, repo) : line;
    result.push(`    ${formatted}`);
  }

  return result;
}

// ---------------------------------------------------------------------------
// buildChangelog - Generate full changelog content
//
// Reads git log between two tags and formats it as markdown.
// Returns the complete changelog as a string.
// Throws: on git command failures or invalid inputs
// ---------------------------------------------------------------------------
interface ChangelogOptions {
  repo: string;
  projectName: string;
  currentTag: string;
  previousTag: string;
  noSubCommits: boolean;
  linkifyPrs: boolean;
}

async function buildChangelog(options: ChangelogOptions): Promise<string> {
  const { repo, projectName, currentTag, previousTag, noSubCommits, linkifyPrs } =
    options;

  // Get tag date
  const tagDate = await getTagDate(currentTag);

  const lines: string[] = [];

  // -- Header ---------------------------------------------------------------
  lines.push(`# ${projectName}`);
  lines.push("");
  lines.push(
    `## [${currentTag}](https://github.com/${repo}/tree/${currentTag}) (${tagDate})`,
  );

  const changelogLink = previousTag
    ? `[Full Changelog](https://github.com/${repo}/compare/${previousTag}...${currentTag})`
    : `[Full Changelog](https://github.com/${repo}/commits/${currentTag})`;

  lines.push(
    `${changelogLink} [Previous Releases](https://github.com/${repo}/releases)`,
  );
  lines.push("");

  // -- Determine log range --------------------------------------------------
  const range = previousTag ? `${previousTag}..${currentTag}` : currentTag;

  // -- Commit list (NUL-delimited records) ----------------------------------
  const rawLog = await gitRaw("log", "--format=%s%n%b%x00", range);
  const records = rawLog.split("\0").filter((r) => r.trim() !== "");

  for (const record of records) {
    const parsed = parseCommitRecord(record);
    if (!parsed) continue;

    // Guard: skip release commits
    if (isReleaseCommit(parsed.subject)) continue;

    // Optionally linkify PR references in subject
    const subject = linkifyPrs
      ? linkifyPrRefs(parsed.subject, repo)
      : parsed.subject;

    lines.push(`- ${subject}`);

    // Skip body entirely when --no-sub-commits is active
    if (!noSubCommits) {
      const bodyFormatted = formatBodyLines(
        parsed.bodyLines,
        linkifyPrs,
        repo,
      );
      lines.push(...bodyFormatted);
    }
  }

  // Trailing newline
  lines.push("");

  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// parseArgs - Parse CLI arguments into a typed options object
//
// Args: argv = command line arguments (excluding script name)
// Returns: ParsedArgs object with validated values
// Throws: on invalid arguments or missing required values
// ---------------------------------------------------------------------------
interface ParsedArgs {
  outputFile: string;
  repo: string;
  tag: string;
  noSubCommits: boolean;
  linkifyPrs: boolean;
  dryRun: boolean;
}

function parseArgs(argv: string[]): ParsedArgs {
  // Input validation: reject null/undefined argv
  if (argv == null) {
    throw new Error("parseArgs requires a non-null argv array");
  }

  let outputFile = ".release/CHANGELOG.md";
  let repo = process.env.GITHUB_REPOSITORY ?? "";
  let tag = "";
  let noSubCommits = false;
  let linkifyPrs = false;
  let dryRun = false;

  let i = 0;
  while (i < argv.length) {
    const arg = argv[i];

    // Early exit: handle --help
    if (arg === "--help") {
      usage();
      // unreachable due to process.exit(0) in usage()
    }

    switch (arg) {
      case "--output": {
        const value = argv[i + 1];
        if (!value || value.trim() === "") {
          die("--output requires a non-empty value");
        }
        outputFile = value.trim();
        i += 2;
        break;
      }

      case "--repo": {
        const value = argv[i + 1];
        if (!value || value.trim() === "") {
          die("--repo requires a non-empty value");
        }
        repo = value.trim();
        i += 2;
        break;
      }

      case "--tag": {
        const value = argv[i + 1];
        if (!value || value.trim() === "") {
          die("--tag requires a non-empty value");
        }
        tag = value.trim();
        i += 2;
        break;
      }

      case "--no-sub-commits":
        noSubCommits = true;
        i += 1;
        break;

      case "--linkify-prs":
        linkifyPrs = true;
        i += 1;
        break;

      case "--dry-run":
        dryRun = true;
        i += 1;
        break;

      default:
        die(`Unknown argument '${arg}'. Run with --help for usage`);
    }
  }

  // Post-parse validation: repo must be set (either from env or CLI)
  if (repo.trim() === "") {
    throw new Error("parseArgs: GITHUB_REPOSITORY must be set or --repo provided");
  }

  return { outputFile, repo, tag, noSubCommits, linkifyPrs, dryRun };
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
async function main(): Promise<void> {
  // Parse arguments first (throws on invalid args)
  const args = parseArgs(process.argv.slice(2));

  // -- Resolve repo (CLI > env > fail) --------------------------------------
  // Validate repo format at this boundary
  if (!REPO_PATTERN.test(args.repo)) {
    die(`Invalid repo format '${args.repo}'. Expected OWNER/REPO`);
  }

  // Derive project name (e.g. "Xerrion/PhDamage" -> "PhDamage")
  const projectName = args.repo.split("/")[1];

  // -- Resolve tags ---------------------------------------------------------
  const currentTag = await resolveCurrentTag(args.tag);
  const previousTag = await resolvePreviousTag(currentTag);

  // -- Build changelog ------------------------------------------------------
  const changelog = await buildChangelog({
    repo: args.repo,
    projectName,
    currentTag,
    previousTag,
    noSubCommits: args.noSubCommits,
    linkifyPrs: args.linkifyPrs,
  });

  // -- Route output ---------------------------------------------------------
  if (args.dryRun) {
    process.stdout.write(changelog);
  } else {
    await mkdir(dirname(args.outputFile), { recursive: true });
    await Bun.write(args.outputFile, changelog);
    console.log(`Changelog written to ${args.outputFile}`);
  }
}

main();
