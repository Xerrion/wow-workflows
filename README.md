# wow-workflows

Shared reusable GitHub Actions workflows for WoW addon release pipelines.

## Repository releases

`self-release.yml` runs on pushes to `main` and can also be dispatched manually. It creates or updates a release PR from conventional commits, such as `feat:` and `fix:`. Merging that PR publishes a GitHub release and a version tag such as `v1.0.0`; it does not run the addon packager.

Release PRs maintain `version.txt`, `.release-please-manifest.json`, and `CHANGELOG.md` using the `simple` strategy in `release-please-config.json`. This repository version is independent of the Rust utility package versions.

In **Settings → Actions → General**, **Allow GitHub Actions to create and approve pull requests** must be enabled. Default workflow permissions can remain read-only; the self-release workflow requests the required writes. It uses the `RELEASE_PLEASE_TOKEN` secret when set (falling back to `GITHUB_TOKEN`, whose bot-created PRs do not trigger other workflows).

## Workflows

### Release (`release.yml`)

Runs release-please to create/update release PRs. When a release PR is merged, it publishes a GitHub release and dispatches the packager workflow to build and upload the addon.

**How it works:**

1. **release-please** creates/updates release PRs via [release-please-action@v4](https://github.com/googleapis/release-please-action). When a release PR is merged, it publishes a GitHub release with a tag.
2. **dispatch** triggers the `packager.yml` workflow in the calling repo via `workflow_dispatch`, passing the new tag name. This avoids the GitHub Actions limitation where tags created by `GITHUB_TOKEN` don't trigger `on: push: tags` workflows, and sidesteps the BigWigsMods/packager "future tag" guard that blocks packaging on branch push events.

**Secrets:** `RELEASE_PLEASE_TOKEN` (fine-grained PAT or GitHub App token with Contents and Pull requests write on the calling repo). Callers pass it with `secrets: inherit`. Without it the workflow falls back to `GITHUB_TOKEN`, and release PRs will not trigger the `pull_request` lint workflow, so required checks never report.

**Inputs:**

| Input | Default | Description |
|-------|---------|-------------|
| `config-file` | `release-please-config.json` | Path to release-please config |
| `manifest-file` | `.release-please-manifest.json` | Path to release-please manifest |

**Outputs:**

| Output | Description |
|--------|-------------|
| `release_created` | Whether a release was created (`true`/`false`) |
| `tag_name` | The release tag name (e.g. `1.2.3`) |

**Caller example:**

```yaml
name: Release

on:
  push:
    branches: [master]

permissions:
  contents: write
  pull-requests: write
  actions: write

jobs:
  release:
    uses: Xerrion/wow-workflows/.github/workflows/release.yml@main
    secrets: inherit
```

> **Note:** The `actions: write` permission is required so the release workflow can dispatch the packager workflow.

### Packager (`packager.yml`)

Generates a changelog and packages/uploads the addon via [BigWigsMods/packager@v2](https://github.com/BigWigsMods/packager-action). Triggered by `workflow_dispatch` from the release workflow (or manually).

**Inputs:**

| Input | Required | Description |
|-------|----------|-------------|
| `tag_name` | Yes | The tag to package (e.g. `1.2.3`) |

**Secrets:**

| Secret | Required | Description |
|--------|----------|-------------|
| `CF_API_KEY` | No | CurseForge API key |
| `WAGO_API_TOKEN` | No | Wago Addons API token |

**Caller example:**

```yaml
name: Package

on:
  workflow_dispatch:
    inputs:
      tag_name:
        description: "The tag to package"
        required: true
        type: string

permissions:
  contents: write

jobs:
  package:
    uses: Xerrion/wow-workflows/.github/workflows/packager.yml@main
    with:
      tag_name: ${{ inputs.tag_name }}
    secrets: inherit
```

### Lint (`lint.yml`)

Runs Luacheck on PRs, with an optional busted test suite.

**Inputs:**

| Input | Default | Description |
|-------|---------|-------------|
| `run-tests` | `false` | Run busted test suite after linting |

**Caller example (lint only):**

```yaml
name: Lint

on:
  pull_request:
    branches: [master]

jobs:
  lint:
    uses: Xerrion/wow-workflows/.github/workflows/lint.yml@main
```

**Caller example (lint + tests):**

```yaml
name: Lint

on:
  pull_request:
    branches: [master]

jobs:
  lint:
    uses: Xerrion/wow-workflows/.github/workflows/lint.yml@main
    with:
      run-tests: true
```

### PR Title (`pr-title.yml`)

Fails a PR whose title is not a conventional commit (`feat:`, `fix(scope):`, ...). Repos squash-merge with the PR title as the commit message, and release-please derives version bumps and changelog entries from it.

Use `PR_TITLE` as the squash commit title in each repo's merge settings.

**Caller example:**

```yaml
name: PR Title

on:
  pull_request:
    branches: [master]
    types: [opened, edited, synchronize, reopened]

permissions:
  pull-requests: read

jobs:
  pr-title:
    uses: Xerrion/wow-workflows/.github/workflows/pr-title.yml@main
```

Fork PRs run this with a read-only token, which is enough: the job only reads the title from the event payload and never checks out PR code.

### PR Labeler (`pr-labeler.yml`)

Adds a category label to a PR from its conventional-commit title, so GitHub's generated release notes (`.github/release.yml`, grouped by label) sort it into the right section:

| Title prefix | Label |
|--------------|-------|
| `feat` | `C-Feature` |
| `fix` | `C-Bug` |
| `perf` | `C-Performance` |
| `refactor` | `C-Code-Quality` |
| `docs`, `doc` | `C-Documentation` |

Other prefixes (`ci`, `chore`, `test`, `style`, `build`, `revert`) get no label and fall under "Other Changes". It never adds a second `C-*` label when one is already set. When a title is edited, it only swaps the label the old title would have produced, so labels set by hand stay. The labels must exist in the repo (shared `C-*` set).

**Caller example:**

```yaml
name: PR Labeler

on:
  pull_request_target:
    branches: [master]
    types: [opened, edited, reopened]

permissions:
  pull-requests: write

jobs:
  label:
    uses: Xerrion/wow-workflows/.github/workflows/pr-labeler.yml@main
```

`pull_request_target` is the one deliberate exception to the `pull_request` rule: under `pull_request`, fork PRs get a read-only token and could not be labeled. It is safe here because the job never checks out PR code and only reads the title from the event payload.

### TOC Update (`toc-update.yml`)

Auto-bumps `## Interface` versions in `.toc` files. Fetches `update_toc_versions.sh` at runtime, runs it against the checked-out repo, and creates a PR via `gh` CLI if any TOC files changed.

**Inputs:**

| Input | Default | Description |
|-------|---------|-------------|
| `flavors` | `"retail classic vanilla tbc forever"` | Space-separated list of game flavors |
| `base-branch` | `"master"` | Base branch for the PR |

No secrets required.

**Caller example:**

```yaml
name: TOC Update

on:
  schedule:
    - cron: "0 12 * * *"
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write
  issues: write

jobs:
  toc-update:
    uses: Xerrion/wow-workflows/.github/workflows/toc-update.yml@main
    with:
      flavors: "retail classic tbc forever"
```

## Scripts

Both scripts live in `scripts/` and are fetched at runtime by the workflows - caller repos do not need local copies.

### `generate_changelog.sh`

Generates a clean markdown changelog for the BigWigsMods packager. It:

- Derives the project name from `GITHUB_REPOSITORY`
- Strips `chore: release` commits and `Co-authored-by` trailer lines
- Writes to `.release/CHANGELOG.md` by default

### `update_toc_versions.sh`

Fetches latest WoW interface versions from the Blizzard CDN v2 (`us.version.battle.net`) and updates `## Interface` directives in `.toc` files.

- Supports flavors: `retail`, `classic`, `vanilla`, `tbc`, `forever`
- Maps each flavor to its CDN product (`wow`, `wow_classic`, `wow_classic_era`, `wow_anniversary`, [`wowf`](https://us.version.battle.net/v2/products/wowf/versions))
- Converts game version strings (e.g. `1.60.1`) to interface version numbers (e.g. `16001`)
- Handles directive variants (`-Classic`, `-Mists`, `-Vanilla`, `-BCC`, `-TBC`, `-Camelot`, `-Forever`)
- Excludes `Libs/` by default; configurable via `--exclude-dir`
- Caches CDN responses and retries on failure

Forever is included by default; workflows with an explicit `flavors` list must add `forever` to that list. It updates existing `16000`–`16999` values in bare `## Interface:` lines, including `_Camelot.toc` files, while preserving other flavor values. It does not add missing directives or flavor values.

`## Interface-Classic:` is ambiguous: the BigWigsMods packager reads it as Classic Era (e.g. `11509`), while older TOCs use it as a Mists alias (e.g. `50504`). The updater resolves it by the range of its current first value: a `50000`–`99999` value is updated by `classic`, a Classic Era value (`10000`–`19999`, excluding Forever's `16000`–`16999`) is updated by `vanilla`, and any other value is left unchanged. A Classic Era `## Interface-Classic:` line is therefore only bumped when `vanilla` is in `flavors`.

## Adopting Repos

- [AddonName](https://github.com/Xerrion/AddonName)
- [DragonLoot](https://github.com/Xerrion/DragonLoot)
- [DragonToast](https://github.com/Xerrion/DragonToast)
- [LibAnimate](https://github.com/Xerrion/LibAnimate)
- [LibDragonFramework](https://github.com/Xerrion/LibDragonFramework)
- [PhDamage](https://github.com/Xerrion/PhDamage)
- [RaidLogAuto](https://github.com/Xerrion/RaidLogAuto)
