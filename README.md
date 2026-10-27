<img src="Resources/AppIcon-1024.png" width="128" alt="DiskCare icon" align="right">

# DiskCare

[![CI](https://github.com/thainph/diskcare/actions/workflows/ci.yml/badge.svg)](https://github.com/thainph/diskcare/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/thainph/diskcare?include_prereleases)](https://github.com/thainph/diskcare/releases)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black)
![Apple silicon](https://img.shields.io/badge/Apple%20silicon-arm64-blue)

**Keep a developer Mac from filling up.** DiskCare is a native menu bar app (plus a CLI) that finds the
disk space development work silently eats — `node_modules`, `.terraform`, Rust `target/`, stale git
worktrees, package-manager and browser caches, forgotten Docker images and volumes — shows what is
safe to remove, and warns you before the disk is full.

> Why: on a typical dev machine a single Rust `target/` grew to 66 GB, 90 `.terraform` folders held
> 72 GB of identical provider binaries across worktrees, and Docker kept 55 GB of images nobody used.
> None of it showed up until the disk hit 100%.

## Features

| | |
|---|---|
| **Overview** | Free space, a breakdown of the disk, and how much can be freed per source — largest first. |
| **Project build files** | Detects regenerable folders (`node_modules`, `.terraform`, `target`, `.venv`, `.next`, `dist`, `Pods`, Gradle, DerivedData…) and groups them by project. Uses git to judge activity: last commit/checkout, uncommitted changes, branch merged into `main`/`develop`. Can remove clean, merged worktrees with `git worktree remove` (branch kept). |
| **Developer caches** | ~45 known locations: pnpm/npm/yarn/uv/pip/Homebrew/Go/Cargo/CocoaPods/SwiftPM, Playwright & Puppeteer browsers (keeps the newest version), Xcode DerivedData and device support, IDE caches. Runs each tool's own cleanup (`brew cleanup`, `pnpm store prune`, `uv cache clean`…) when installed. Local AI models and other user data are shown but never cleaned. |
| **Docker** | Reads the Engine API socket (OrbStack, Docker Desktop). Safe removals (unused images, build cache, stopped containers, anonymous volumes) are separated from named volumes that may hold databases — those are archived to `~/DiskCareBackups` first and can be restored. |
| **Growth** | Every scan is recorded (SQLite). See what grew this week, and get a notification when a build folder balloons — an FSEvents watcher re-measures only the folders that changed. |
| **Prevention** | Checks tool settings that stop waste from coming back — Terraform `plugin_cache_dir`, a shared Cargo `target-dir`, pnpm migration, Docker build-cache GC — with one-click fixes that show the diff and back up the file first. |
| **CLI** | Everything above is scriptable with `diskcare`. Destructive commands are dry runs unless `--apply`. |

**Designed to be invisible:** automatic scans run step by step on a single background thread with
throttled disk I/O (they yield to every other app), show their progress, and the last results appear
instantly at launch. Idle CPU is ~0%.

## Install

Requirements: macOS 15 or later on Apple silicon (arm64).

1. Download `DiskCare-<version>-arm64.dmg` from [Releases](https://github.com/thainph/diskcare/releases).
2. Open it and drag **DiskCare** to **Applications**.
3. Preview builds are ad-hoc signed (not notarized). The first time, either right-click the app → **Open**, or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/DiskCare.app
   ```
4. DiskCare appears in the menu bar (no Dock icon). Open it again from Finder/Spotlight to show the main window.

**Recommended:** grant *Full Disk Access* (System Settings → Privacy & Security) so caches inside
protected folders can be measured. Choose which folders to scan in **Settings** (defaults to
`~/Workspace`, `~/Tools`, `~/Development`, `~/Projects`, `~/Code`… when present).

### CLI only

```bash
curl -LO https://github.com/thainph/diskcare/releases/latest/download/diskcare-cli-0.1.1-arm64.tar.gz
tar -xzf diskcare-cli-0.1.1-arm64.tar.gz && sudo mv diskcare /usr/local/bin/
```

The CLI is also inside the app: `/Applications/DiskCare.app/Contents/Resources/diskcare`.

## CLI usage

```bash
diskcare scan ~/Workspace ~/Tools --top 20         # what is using space, by kind / workspace
diskcare clean ~/Workspace --idle-days 30          # cleanup plan (dry run)
diskcare clean ~/Workspace --kind .terraform --remove-merged-worktrees --apply

diskcare caches                                    # global developer caches
diskcare caches clean --all-safe --apply

diskcare docker                                    # Docker usage report
diskcare docker clean --images --build-cache --apply
diskcare docker clean --project myapp --apply      # named volumes: backed up first
diskcare docker restore ~/DiskCareBackups/docker-volumes/<archive>.tar.gz

diskcare history --days 7                          # free-space trend, top growth
diskcare watch ~/Workspace                         # live growth events (FSEvents)
diskcare doctor ~/Workspace                        # prevention advice
diskcare doctor --fix terraform-plugin-cache       # shows the diff, backs up, asks first
```

Add `--json` to `scan`, `clean`, `caches`, `docker`, `history` and `doctor` for machine-readable output.

## Safety

- Only folders a tool can rebuild are suggested; ambiguous names (`build`, `dist`, `target`, `vendor`…)
  require a matching project file next to them, and nothing inside `third_party/` is touched.
- Every path is re-validated right before deletion (still a real directory, inside a scanned root).
- Worktrees are removed with `git worktree remove` (never `--force`), only when clean and merged.
- Docker named volumes are archived and verified before deletion; anything in use is skipped.
- Config fixes back up the original file next to it (`<file>.diskcare-backup-<timestamp>`).
- Optional *Move to Trash* mode instead of deleting.

## Data & privacy

DiskCare runs fully locally: no telemetry, no network calls of its own (Docker volume backups ask
your local Docker daemon to pull `alpine` once). Files it writes:

| Path | Purpose |
|---|---|
| `~/Library/Application Support/DiskCare/history.sqlite` | scan history for growth reports |
| `~/Library/Application Support/DiskCare/last-scan.json` | last results, shown instantly at launch |
| `~/DiskCareBackups/docker-volumes/` | Docker volume archives |

## How sizes are measured

- Allocated size on disk (`ATTR_FILE_ALLOCSIZE`), not logical size; hard-linked files (e.g. pnpm
  store links) are counted once, and the hard-linked share is shown because deleting it may not free it.
- The scanner uses `getattrlistbulk(2)` (one syscall per few hundred entries) and stays on the
  scanned volume (skips network mounts such as `~/OrbStack`). It reads ~1M files in ~5 s with 4 threads.

## Build from source

```bash
git clone https://github.com/thainph/diskcare.git && cd diskcare
swift test                                   # unit tests
./scripts/make-icon.sh                       # re-render Resources/AppIcon.icns (only after editing the icon)
./scripts/bundle-app.sh                      # → .build/DiskCare.app (ad-hoc signed, arm64)
open .build/DiskCare.app
./scripts/package-release.sh                 # → dist/ (dmg, zip, CLI tarball, SHA256SUMS)
```

Requires Xcode 16+ (Swift 6). Project layout:

```
Sources/DiskCareCore   engine: scanner, artifact rules, git, cleanup, caches, Docker, history, watcher, doctor
Sources/diskcare       CLI (swift-argument-parser)
Sources/DiskCareApp    SwiftUI menu bar app
Tests/                 swift-testing suites
Resources/             AppIcon.icns + 1024 px PNG (rendered by scripts/make-icon.swift)
scripts/               bundle-app.sh, package-release.sh, make-icon.sh
```

## CI/CD

- **CI** (`.github/workflows/ci.yml`): every push/PR builds for arm64 on a `macos-15` runner, runs
  the tests and bundles the app as a smoke test.
- **Release** (`.github/workflows/release.yml`): pushing a tag `vX.Y.Z` (must match
  `DiskCareVersion.current`) runs the tests, builds `DiskCare.app` for Apple silicon, packages
  `.dmg`, `.zip`, the CLI tarball and checksums, and publishes a GitHub release with notes from
  `CHANGELOG.md`.
- **Signing (optional):** add these repository secrets to sign with Developer ID and notarize;
  without them builds are ad-hoc signed.

  | Secret | Value |
  |---|---|
  | `MACOS_CERTIFICATE` | base64 of the Developer ID Application `.p12` |
  | `MACOS_CERTIFICATE_PASSWORD` | `.p12` password |
  | `MACOS_SIGN_IDENTITY` | e.g. `Developer ID Application: Your Name (TEAMID)` |
  | `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` | Apple ID, team ID, app-specific password |

### Releasing

```bash
# 1. bump Sources/DiskCareCore/Support/Version.swift and add a CHANGELOG.md section
# 2. commit, then tag and push
git tag -a v0.2.0 -m "DiskCare 0.2.0" && git push origin main v0.2.0
```
