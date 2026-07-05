# Build Workflow

## Quick Reference

| Flag | Purpose | Who | Build time | Requires |
|------|---------|-----|-----------|----------|
| *(default)* | Auto-detect: use cache if available, otherwise full build | Anyone | 15 min (cached) / 1-3 hrs (full) | Tag |
| `--restore-cache` | Pull pre-built deps from LFS to local cache | Anyone | ~2 min | Nothing |
| `--full` | Rebuild all dependencies from source | Anyone | 1-3 hours | Tag |
| `--promote` | Archive verified build to LFS | Maintainer | ~1 min | Verified build |
| `--cleanup-lfs` | Restore proven/ to pointers, prune LFS cache | Anyone | ~10 sec | Nothing |

## First-Time Setup

Choose your path based on whether you want to use pre-built dependencies or compile everything yourself.

```mermaid
flowchart TD
    A["<b>git clone</b> repo<br/><i>~1 MB, no binaries</i>"] --> B{"Want pre-built<br/>dependencies?"}

    B -->|Yes| C["<b>--restore-cache</b><br/>Pull from Git LFS"]
    C --> D["Local cache populated<br/><i>~/opt/proven/{arch}/</i>"]
    D --> E["<b>./build-local.sh</b> tag<br/><i>~15 min</i>"]

    B -->|No| F["<b>./build-local.sh</b> tag<br/><i>~1-3 hours</i>"]

    E --> G["DMG ready"]
    F --> G

    style A fill:#e8f4fd,stroke:#2196f3,stroke-width:2px,color:#000
    style G fill:#e8f5e9,stroke:#4caf50,stroke-width:2px,color:#000
```

## Build Mode Decision Tree

What happens inside the build script depending on the flag you pass.

> Before any of these modes runs, the build script verifies the upstream release tag's GPG signature against the pinned mbunkus key, and SHA256-verifies each package on cache restore. See [trust-model.md](trust-model.md) for the verification chain.

```mermaid
flowchart TD
    START["./build-local.sh [flag] tag"] --> MODE{Flag?}

    MODE -->|--restore-cache| RC1["Pull LFS for current arch"]
    RC1 --> RC2["Copy to ~/opt/proven/{arch}/"]
    RC2 --> RC3["Verify all packages arrived"]
    RC3 --> RC4["Clean up repo LFS objects"]
    RC4 --> RC5(("Exit<br/><i>cache ready</i>"))

    MODE -->|--full| F1["Wipe workspace"]
    F1 --> F2["Build ALL deps from source"]
    F2 --> POST

    MODE -->|default / auto| A1["Wipe workspace"]
    A1 --> A2{"~/opt/proven/{arch}/<br/>has all packages?"}
    A2 -->|Yes| A3["Restore deps from cache"]
    A3 --> A4["Build mkvtoolnix only"]
    A4 --> POST
    A2 -->|No| A5["Build ALL deps from source"]
    A5 --> POST

    MODE -->|--promote| P1{"Previous build<br/>verified?"}
    P1 -->|No| P2(("Error<br/><i>build first</i>"))
    P1 -->|Yes| P3["Archive current proven to LFS"]
    P3 --> P4["Swap local cache with new packages"]
    P4 --> P5["Commit new proven to LFS"]
    P5 --> P6["Clean up repo LFS objects"]
    P6 --> P7(("Exit<br/><i>push when ready</i>"))

    POST["Package DMG"] --> VERIFY["Post-build verification"]
    VERIFY --> DONE(("Done<br/><i>DMG ready</i>"))

    style RC5 fill:#e8f5e9,stroke:#4caf50,stroke-width:2px,color:#000
    style P2 fill:#ffebee,stroke:#f44336,stroke-width:2px,color:#000
    style P7 fill:#e8f5e9,stroke:#4caf50,stroke-width:2px,color:#000
    style DONE fill:#e8f5e9,stroke:#4caf50,stroke-width:2px,color:#000
```

## Dependency Lifecycle

How dependencies flow between Git LFS, the local cache, and the build system. There are two halves: a **consumer path** that everyone uses, and a **promotion path** that's maintainer-only.

### Consumer path (everyone)

```mermaid
flowchart LR
    LFS["<b>Git LFS</b><br/><i>proven/{arch}/</i><br/>archival storage"]
    LC["<b>Local Cache</b><br/><i>~/opt/proven/{arch}/</i>"]
    BUILD(("Build"))
    PKG["<b>DMG</b><br/><i>~/opt/packages/</i>"]
    FULL["<b>--full</b><br/><i>(skip cache,<br/>build all from source)</i>"]

    LFS -->|"--restore-cache"| LC
    LC -->|"auto-restore"| BUILD
    FULL --> BUILD
    BUILD -->|"produces"| PKG

    style LFS fill:#e8f4fd,stroke:#2196f3,stroke-width:2px,color:#000
    style PKG fill:#e8f5e9,stroke:#4caf50,stroke-width:2px,color:#000
    style BUILD fill:#f3e5f5,stroke:#9c27b0,stroke-width:2px,color:#000
```

Most users only ever do this: pull dependencies from LFS into the local cache (or skip the cache with `--full` and build everything from source), run a build, get a DMG.

### Promotion path (maintainer only)

```mermaid
flowchart LR
    PKG["<b>Verified Packages</b><br/><i>~/opt/packages/</i><br/>(after a clean build)"]
    LFS["<b>Git LFS</b><br/><i>proven/{arch}/</i><br/>archived for the next consumer"]

    PKG -->|"--promote<br/>(maintainer only)"| LFS

    style PKG fill:#e8f5e9,stroke:#4caf50,stroke-width:2px,color:#000
    style LFS fill:#e8f4fd,stroke:#2196f3,stroke-width:2px,color:#000
```

After a verified build, the maintainer archives the new packages back to LFS so the next person to run `--restore-cache` picks them up. This is a separate operation, not part of the build itself.

> **The two halves form a loop in time, not space:** today's `--promote` becomes tomorrow's `--restore-cache` for the next person to clone fresh.

## Existing Clones (Reclaiming Disk Space)

If you cloned the repo before `.lfsconfig` was added, or cloned with `git lfs pull`, the `proven/` directory contains full binary files (~264 MB) and `.git/lfs/objects/` holds another copy (~270 MB). Here's how to reclaim that space.

### Option A: Keep deps for building, clean up repo (recommended)

Use `--restore-cache` to copy the already-downloaded binaries to your local build cache, then clean up the repo:

```sh
./build-local.sh --restore-cache
```

This copies the deps to `~/opt/proven/{arch}/`, restores `proven/` to pointer files, and prunes the LFS cache. Repo drops from ~535 MB to ~1 MB. Future builds use the local cache.

### Option B: Just reclaim space (no build planned)

If you don't need the dependencies at all:

```sh
./build-local.sh --cleanup-lfs
```

This restores `proven/` to pointer files and prunes the LFS cache. No files are copied anywhere.

### Option C: Manual cleanup (no script)

If you prefer to handle it yourself:

```sh
# Step 1: Restore proven/ files to LFS pointers
# GIT_LFS_SKIP_SMUDGE prevents checkout from re-downloading the real files
GIT_LFS_SKIP_SMUDGE=1 git checkout -- proven/

# Step 2: Verify files are now pointers (should be ~130 bytes each)
wc -c proven/arm/*.tar.gz | tail -1

# Step 3: Prune the LFS object cache (removes downloaded objects no longer
# referenced by the working copy)
git lfs prune

# Step 4: Verify space reclaimed
du -sh .git/lfs/objects/   # should be ~0 bytes
du -sh .                   # should be ~1 MB total
```

After any of these options, future `git pull` will not re-download LFS objects thanks to `.lfsconfig`.

```mermaid
flowchart TD
    A{"Already cloned<br/>with LFS objects?"}
    A -->|"Yes, want to build"| B["<b>--restore-cache</b><br/>Copy to local cache + cleanup"]
    A -->|"Yes, don't need deps"| C["<b>--cleanup-lfs</b><br/>Just restore pointers"]
    A -->|"Yes, prefer manual"| D["Manual: git checkout + lfs prune"]
    A -->|No| E["Nothing to do<br/><i>.lfsconfig prevents auto-download</i>"]

    B --> F["Repo ~1 MB<br/>Local cache ~130 MB"]
    C --> G["Repo ~1 MB"]
    D --> G

    style B fill:#e8f5e9,stroke:#4caf50,stroke-width:2px,color:#000
    style C fill:#e8f4fd,stroke:#2196f3,stroke-width:2px,color:#000
    style D fill:#fff3e0,stroke:#ff9800,stroke-width:2px,color:#000
    style E fill:#f5f5f5,stroke:#9e9e9e,stroke-width:2px,color:#000
```

## Build Numbers

Each build increments a per-architecture counter. As of 2026-05-06, production and experimental builds use separate counters:

- Production (release-track) builds: `.build-counter-arm-rel`, `.build-counter-intel-rel`
- Experimental builds (`tools/build-exp.sh`): `.build-counter-arm-exp`, `.build-counter-intel-exp`

These files are **tracked in git on purpose**, so the counter persists across machines. If you build on your desktop (counter reaches 13) then push, a subsequent build on your laptop continues from 14 instead of restarting at 1. Build numbers appear in internal DMG filenames:

- Production: `MKVToolNix-{ver}-{arch}-rel{NNN}-{branch}.dmg`
- Experimental: `MKVToolNix-{ver}-{arch}-exp{NNN}-{slug}-{hash}.dmg`

This correlates binaries with entries in `build-report-{tag}.txt`, which helps when diagnosing failures across machines. Builds before 2026-05-06 used a single combined `.build-counter-{arm,intel}` with a `b{NNN}` prefix; pre-rename DMGs in `build/` retain those filenames as historical record.

### Resetting the counter

If you cloned this repo for your own use and want to start build numbering fresh on a new machine, delete the relevant counter files before your first build:

```sh
rm .build-counter-arm-rel .build-counter-intel-rel
rm .build-counter-arm-exp .build-counter-intel-exp
# or just the ones for your architecture and build type
```

The counter then restarts at 1 and increments locally from there. **Do not push resets back to this repo** — doing so would collide with the maintainer's build numbering.

## Experimental Dependency Cache

For experimental builds (e.g. testing against upstream `main` with a bumped Qt version), recompiling multi-hour dependencies like Qt on every iteration is wasteful. The proven cache shouldn't absorb those builds — it's versioned to the current release — so there's a second, purely-local tier:

- `~/opt/proven-experimental/{arm,intel}/` — never pushed, never committed, machine-specific.

### How the overlay works

`build-local.sh` checks the experimental cache **first** for each expected package, falling back to the main proven cache. Packages are matched by exact filename, which includes the version:

- `qt-everywhere-src-6.11.1.tar.gz` lives in proven (the current release's Qt)
- a newer `qt-everywhere-src-*.tar.gz` could live in experimental (staged while you test an upstream Qt bump)

Both are safe to coexist — the build picks whichever the active `specs.sh` + `QTVER` combination is looking for.

### Staging and clearing

After a successful experimental build (packages are in `~/opt/packages/`):

```sh
./build-local.sh --stage-experimental
```

Copies all built package tarballs into `~/opt/proven-experimental/{arch}/`. Subsequent builds that need any of those versions restore them in seconds instead of recompiling.

To revert to the main proven cache only (e.g. when you're done experimenting or want a clean slate):

```sh
./build-local.sh --clear-experimental
```

Deletes `~/opt/proven-experimental/{arch}/` for the current architecture. The main proven cache is untouched.

### When to stage vs when to promote

| Use case | Action |
|----------|--------|
| You built Qt 6.11 against upstream main; iterating on patches | `--stage-experimental` — keeps Qt compiled between runs |
| The experimental work graduates to a real release | Retire local patches, merge branch, run normal `--full` build, then `--promote` |
| You want to test a totally different Qt configuration | `--clear-experimental`, then build, then `--stage-experimental` again |

`--stage-experimental` never touches git or LFS. `--promote` still behaves exactly as before and still refuses to run outside the `main` branch.

## Common Workflows

### Update documentation (no build needed)

```sh
git clone https://github.com/CorticalCode/mkvtoolnix-gui-macos.git
cd mkvtoolnix-gui-macos
# Edit docs, commit, push — no LFS objects downloaded
```

### First build on a new machine (fast path)

```sh
git clone https://github.com/CorticalCode/mkvtoolnix-gui-macos.git
cd mkvtoolnix-gui-macos
./build-local.sh --restore-cache          # ~2 min, populates local cache
./build-local.sh release-XX.X             # ~15 min, uses cached deps
```

### First build on a new machine (from source)

```sh
git clone https://github.com/CorticalCode/mkvtoolnix-gui-macos.git
cd mkvtoolnix-gui-macos
./build-local.sh release-XX.X             # ~1-3 hours, builds everything
```

### Subsequent builds (cache already populated)

```sh
./build-local.sh release-XX.X             # ~15 min, auto-restores from cache
```

### Promote after verified build (maintainer only)

```sh
./build-local.sh --full release-XX.X      # Full rebuild from source
./build-local.sh --promote release-XX.X   # Archive to LFS, clean up
git push                                  # Share with others
```
