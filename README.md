# wow-workflows

Shared reusable GitHub Actions workflows for WoW addon release pipelines.

## Workflows

### Release (`release.yml`)

End-to-end release pipeline combining release-please and BigWigsMods/packager into a single workflow call. Two jobs:

1. **release-please** - Creates/updates release PRs via [release-please-action@v4](https://github.com/googleapis/release-please-action). When a release PR is merged, it publishes a GitHub release and emits outputs.
2. **package** - Gated on `release_created == 'true'`. Generates a changelog, then packages and uploads the addon via [BigWigsMods/packager@v2](https://github.com/BigWigsMods/packager-action).

> **Why one workflow?** The previous two-workflow design (`release-pr.yml` + tag-triggered `release.yml`) required a `GITHUB_OAUTH` PAT because tags created by `GITHUB_TOKEN` do not trigger downstream `on: push: tags` workflows. Combining both jobs into one `workflow_call` eliminates that limitation - the package job runs in the same workflow run as release-please, so no secondary trigger is needed.

**Inputs:**

| Input | Default | Description |
|-------|---------|-------------|
| `config-file` | `release-please-config.json` | Path to release-please config |
| `manifest-file` | `.release-please-manifest.json` | Path to release-please manifest |

**Secrets:**

| Secret | Required | Description |
|--------|----------|-------------|
| `CF_API_KEY` | No | CurseForge API key |
| `WAGO_API_TOKEN` | No | Wago Addons API token |

**Outputs:**

| Output | Description |
|--------|-------------|
| `release_created` | Whether a release was created (`true`/`false`) |
| `tag_name` | The release tag name (e.g. `v1.2.3`) |

**Caller example:**

```yaml
name: Release

on:
  push:
    branches: [master]

permissions:
  contents: write
  pull-requests: write

jobs:
  release:
    uses: Xerrion/wow-workflows/.github/workflows/release.yml@main
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
