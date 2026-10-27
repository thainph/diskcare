# Changelog

All notable changes to DiskCare are documented here. Versions follow [Semantic Versioning](https://semver.org).

## [Unreleased]

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
