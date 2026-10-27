# DiskCare

macOS tool that finds and cleans disk space wasted by development: build artifacts, dependencies,
stale git worktrees, developer caches and unused Docker data — and warns before the disk fills up.

- `DiskCareCore` — engine: getattrlistbulk-based parallel scanner, artifact rules, git inspection,
  cleanup planner, global cache catalog, Docker Engine API client, SQLite history, FSEvents growth
  watcher, doctor checks
- `diskcare` — CLI
- `DiskCareApp` — menu bar app + main window (Overview, Projects, Docker, Caches, Growth, Doctor)

## Build & run

```bash
swift build -c release
./scripts/bundle-app.sh && open .build/DiskCare.app   # menu bar app
swift test
```

## CLI

All destructive commands are dry runs unless `--apply` is passed.

```bash
diskcare scan ~/Workspace ~/Tools --top 20 --min-size 300MB   # records into history (--no-record to skip)
diskcare clean ~/Workspace --idle-days 30                     # plan only
diskcare clean ~/Workspace --kind .terraform --remove-merged-worktrees --apply
diskcare caches                                               # global developer caches
diskcare caches clean --all-safe --apply
diskcare docker                                               # Docker usage report
diskcare docker clean --images --build-cache --project pms --apply   # named volumes are backed up first
diskcare docker restore ~/DiskCareBackups/docker-volumes/<archive>.tar.gz
diskcare history --days 7                                     # free-space trend and top growth
diskcare watch ~/Workspace                                    # live FSEvents growth events
diskcare doctor ~/Workspace                                   # prevention advice
diskcare doctor --fix terraform-plugin-cache                  # shows diff, backs up, asks first
```

## How sizes are measured

- Allocated size on disk (`ATTR_FILE_ALLOCSIZE`), not logical size.
- Hard-linked files (e.g. pnpm store links) are counted once per scan; the `LINKED` column shows
  the part of an artifact made of hard links, which deleting the artifact may not free.
- The scan stays on the root's volume (skips network mounts such as `~/OrbStack`).

## Data locations

- History: `~/Library/Application Support/DiskCare/history.sqlite`
- Docker volume backups: `~/DiskCareBackups/docker-volumes/`
- Config backups made by `doctor --fix`: `<file>.diskcare-backup-<timestamp>` next to the file
