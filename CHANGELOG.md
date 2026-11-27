# Changelog

All notable changes to DiskCare are documented here. Versions follow [Semantic Versioning](https://semver.org).

## [0.2.0] - 2026-11-28

Fixes the root causes of a disk that filled up unnoticed (a 141 GB shared Cargo target dir that
`doctor --fix` had set up and nothing measured), and a redesigned, bilingual app.

### Added
- **Shared Cargo build dirs** (`build.target-dir`, `build.build-dir`, `CARGO_TARGET_DIR`, also from shell rc
  files and `.cargo/config.toml` above scan roots) are measured under Caches. Only their `incremental/`
  dirs are preselected; whole profiles are manual, a running build (Cargo's lock) or binary blocks them.
- Configured Terraform plugin cache, pnpm `store-dir` and sccache locations are measured; a configured
  location is only cleaned when it looks like the tool's own cache.
- Terraform plugin cache: old provider versions are suggested only when no scanned project uses them.
- Deletion audit log (`~/Library/Application Support/DiskCare/deletions.jsonl`); leftovers of an
  interrupted delete are listed and finished.
- **Where is the rest?** (Insights) and `diskcare explain`: large folders outside projects and caches,
  `/Applications` and Homebrew sizes, local snapshots and what stays unaccounted for. Runs by itself
  when free space drops by 10 GB / 2% that the scans do not explain. Report only.
- **App data**: big folders in `~/Library/Application Support` (chat apps, AI apps…), report only.
  Privacy-protected folders are never read.
- Low-space alerts at `max(50 GB, 15%)` and critical at 8%, checked every 15 minutes without scanning,
  with a "full in N days" forecast and the fastest-growing sources. Free space now matches `df`
  (purgeable space shown separately).
- First-run welcome with "Launch at login" on by default, catch-up scans after wake, and the age of the
  last full scan (yellow after 2 days, red after 7); `diskcare doctor` reports a stale last scan.
- **Redesigned app (Liquid Glass on macOS 26)**: four sections — Overview, Clean up, Insights,
  Prevention. The Overview answers "how much is free and is it fine" with one "Clean X safely" action;
  Clean up lists projects, caches and Docker in one place grouped by safety (Safe, Needs re-download
  or rebuild, Report only) with one review sheet; Insights shows the 30-day free-space chart, what grew
  fastest and where the rest of the disk is.
- **English and Vietnamese** interface (Settings › Language; follows macOS by default).
- `scripts/make-local-signing-identity.sh`: local builds signed with one identity keep macOS
  permissions such as Full Disk Access across rebuilds.

### Changed
- Doctor: `cargo-build-cache` replaces `cargo-shared-target`. It no longer recommends a shared
  target dir (it never goes stale and filled a 460 GB disk); it suggests sccache and warns when a
  shared dir exceeds 15 GB.
- Deletion safety: paths are compared by inode (firmlinks, `/tmp` vs `/private/tmp`, letter case),
  unnormalized paths are refused, the checked directory must still be the one deleted, and personal
  folders are protected. Old versions/stale projects are suggested but no longer preselected.
- Cleaning more than 20 GB, or anything that must be rebuilt, needs an explicit acknowledgement in the
  review sheet. Project suggestions are no longer preselected.
- CI and releases build on macOS 26 runners (SDK 26).

## [0.1.1] - 2026-10-27

### Added
- App icon (disk gauge with a sparkle), rendered from code by `scripts/make-icon.swift`.

## [0.1.0] - 2026-10-27

First public preview for macOS 15+ on Apple silicon.

### Added
- **Menu bar app** with a glanceable popover (free space, how much can be freed and where) and a
  main window: Overview, Projects, Caches, Docker, Growth and Prevention pages.
- **Project build files**: finds `node_modules`, `.terraform`, Rust `target`, Python venvs,
  `.next`/`.nuxt`, `dist`/`build`, Gradle, Pods, DerivedData… in idle projects and git worktrees,
  using git state (last commit/checkout, uncommitted changes, merged branches) to decide what is safe.
- **Developer caches**: ~45 known cache locations (pnpm/npm/uv/pip/Homebrew/Go/Cargo, Playwright and
  Puppeteer browsers, Xcode DerivedData and device support…), using each tool's own cleanup command
  when installed. User data such as local AI models is reported but never cleaned.
- **Docker**: usage report through the Engine API (OrbStack, Docker Desktop), removal of unused images,
  build cache and stopped containers; unused named volumes are archived to `~/DiskCareBackups`
  before deletion and can be restored.
- **Growth**: scan history in SQLite, 7-day growth report and a live FSEvents watcher that notifies
  when a build folder grows fast (e.g. a Rust `target/` ballooning).
- **Prevention ("doctor")**: checks and one-click fixes for Terraform plugin cache and a shared Cargo
  target dir, plus advice for pnpm, Docker build-cache GC and Time Machine snapshots.
- **`diskcare` CLI** with `scan`, `clean`, `caches`, `docker`, `history`, `watch` and `doctor`;
  every destructive command is a dry run unless `--apply` is given.
- Low-impact scanning: automatic scans run step by step on one background thread with throttled
  disk I/O and show progress; previous results are shown instantly at launch.
