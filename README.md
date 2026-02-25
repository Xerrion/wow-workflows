# wow-workflows

Shared reusable GitHub Actions workflows for WoW addon release pipelines.

## Workflows

### Release PR (`release-pr.yml`)

Wraps [release-please-action](https://github.com/googleapis/release-please-action) to create/update release PRs on push to master.

**Inputs:**

| Input | Default | Description |
|-------|---------|-------------|
| `config-file` | `release-please-config.json` | Path to release-please config |
| `manifest-file` | `.release-please-manifest.json` | Path to release-please manifest |

**Caller example:**

```yaml
name: Release PR

on:
  push:
    branches: [master]

jobs:
  release-pr:
    uses: Xerrion/wow-workflows/.github/workflows/release-pr.yml@main
    secrets: inherit
```

### Release (`release.yml`)

Resolves the release tag, generates a changelog, and packages the addon via [BigWigsMods/packager](https://github.com/BigWigsMods/packager-action).

**Inputs:**

| Input | Default | Description |
|-------|---------|-------------|
| `tag_name` | `""` | Tag to package (for `workflow_dispatch` callers) |

**Secrets:**

| Secret | Required | Description |
|--------|----------|-------------|
| `CF_API_KEY` | No | CurseForge API key |
| `WAGO_API_TOKEN` | No | Wago Addons API token |
| `GITHUB_OAUTH` | Yes | GitHub token for packager |

**Caller example:**

```yaml
name: Release

on:
  push:
    tags: ["*"]
  workflow_dispatch:
    inputs:
      tag_name:
        description: "Tag to package (e.g. 1.4.3)"
        required: true
        type: string

jobs:
  release:
    uses: Xerrion/wow-workflows/.github/workflows/release.yml@main
    with:
      tag_name: ${{ inputs.tag_name || '' }}
    secrets: inherit
```

## Changelog Script

`scripts/generate_changelog.sh` generates a clean markdown changelog for the BigWigsMods packager. It:

- Derives the project name dynamically from `GITHUB_REPOSITORY`
- Strips `chore: release` commits
- Removes `Co-authored-by` trailer lines
- Writes to `.release/CHANGELOG.md` by default

The release workflow fetches this script automatically - caller repos do NOT need a local copy.

## Adopting Repos

- [PhDamage](https://github.com/Xerrion/PhDamage)
- [DragonToast](https://github.com/Xerrion/DragonToast)
- [DragonLoot](https://github.com/Xerrion/DragonLoot)
- [LibAnimate](https://github.com/Xerrion/LibAnimate)
