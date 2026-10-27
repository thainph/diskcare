# DiskCare

macOS tool that finds disk space wasted by build artifacts, dependencies and stale git worktrees.

- `DiskCareCore` — scanning engine (getattrlistbulk-based parallel walker, artifact rules, git inspection)
- `diskcare` — CLI
- `DiskCareApp` — menu bar app (SwiftUI `MenuBarExtra`)

## Build & run

```bash
swift build -c release
.build/release/diskcare scan ~/Workspace ~/Tools --top 20 --min-size 300MB
.build/release/diskcare scan ~/Workspace --json > report.json
.build/release/diskcare clean ~/Workspace --idle-days 30          # dry-run cleanup plan
.build/release/diskcare clean ~/Workspace --remove-merged-worktrees --apply
.build/release/diskcare docker  # Docker disk usage via the Engine API socket (read-only)
./scripts/bundle-app.sh && open .build/DiskCare.app   # menu bar app
swift test
```

## How sizes are measured

- Allocated size on disk (`ATTR_FILE_ALLOCSIZE`), not logical size.
- Hard-linked files (e.g. pnpm store links) are counted once per scan; the `LINKED` column shows
  the part of an artifact made of hard links, which deleting the artifact may not free.
- The scan stays on the root's volume (skips network mounts such as `~/OrbStack`).
