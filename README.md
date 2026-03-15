# wow-workflows

Shared reusable GitHub Actions workflows for WoW addon release pipelines.

## Workflows

### Release (`release.yml`)

Runs release-please to create/update release PRs. When a release PR is merged, it publishes a GitHub release and dispatches the packager workflow to build and upload the addon.

**How it works:**

1. **release-please** creates/updates release PRs via [release-please-action@v4](https://github.com/googleapis/release-please-action). When a release PR is merged, it publishes a GitHub release with a tag.
2. **dispatch** triggers the `packager.yml` workflow in the calling repo via `workflow_dispatch`, passing the new tag name. This avoids the GitHub Actions limitation where tags created by `GITHUB_TOKEN` don't trigger `on: push: tags` workflows, and sidesteps the BigWigsMods/packager "future tag" guard that blocks packaging on branch push events.

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
  pull_request_target:
    branches: [master]

jobs:
  lint:
    uses: Xerrion/wow-workflows/.github/workflows/lint.yml@main
```

**Caller example (lint + tests):**

```yaml
name: Lint

on:
  pull_request_target:
    branches: [master]

jobs:
  lint:
    uses: Xerrion/wow-workflows/.github/workflows/lint.yml@main
    with:
      run-tests: true
```

### TOC Update (`toc-update.yml`)

Auto-bumps `## Interface` versions in `.toc` files. Fetches `update_toc_versions.sh` at runtime, runs it against the checked-out repo, and creates a PR via `gh` CLI if any TOC files changed.

**Inputs:**

| Input | Default | Description |
|-------|---------|-------------|
| `flavors` | `"retail classic vanilla tbc"` | Space-separated list of game flavors |
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
      flavors: "retail classic tbc"
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

- Supports flavors: `retail`, `classic`, `vanilla`, `tbc`
- Maps each flavor to its CDN product (`wow`, `wow_classic`, `wow_classic_era`, `wow_anniversary`)
- Converts game version strings (e.g. `12.0.1`) to interface version numbers (e.g. `120001`)
- Handles directive variants (`-Classic`, `-Mists`, `-Vanilla`, `-BCC`, `-TBC`)
- Excludes `Libs/` by default; configurable via `--exclude-dir`
- Caches CDN responses and retries on failure

## Adopting Repos

- [AddonName](https://github.com/Xerrion/AddonName)
- [DragonLoot](https://github.com/Xerrion/DragonLoot)
- [DragonToast](https://github.com/Xerrion/DragonToast)
- [LibAnimate](https://github.com/Xerrion/LibAnimate)
- [LibDragonFramework](https://github.com/Xerrion/LibDragonFramework)
- [PhDamage](https://github.com/Xerrion/PhDamage)
- [RaidLogAuto](https://github.com/Xerrion/RaidLogAuto)
