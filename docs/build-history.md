# Build History

Index of every DMG build produced by `build-local.sh` with provenance, release mapping, and preservation status. Source of truth for answering "what was built when, and what happened to it."

## Schema

| Field | Meaning |
|-------|---------|
| **#** | Build counter (`.build-counter-{arm,intel}`, advances on every successful build) |
| **Arch** | `arm` (Apple Silicon) or `intel` (x86_64) |
| **Type** | `main` (built on main branch with build-local.sh) · `feature` (feature/fix branch with build-local.sh) · `experimental` (experimental/* branch with build-local.sh) · `fork` (legacy `tools/build-fork.sh` build, used through 2026-05-06) · `exp` (`tools/build-exp.sh` build from an experimental worktree) |
| **Date** | Local time of build completion |
| **Branch/Slug** | Git branch name at build time (sanitized for filename) |
| **DMG** | Filename in `build/`, or `—` if missing |
| **SHA256** | First 10 chars, see `build/<name>.sha256` for full |
| **Log** | Build log path, or `—` if absent (logs/ feature added after b013) |
| **Release** | GitHub release tag + asset name if shipped · `retracted: <tag>` if pulled · `—` otherwise |
| **Notes** | Status and context |

## ARM (Apple Silicon) builds

| # | Arch | Type | Date | Branch/Slug | DMG | SHA256 | Log | Release | Notes |
|---|------|------|------|-------------|-----|--------|-----|---------|-------|
| b001 | arm | feature | 2026-04-13 12:54 | smart-build | `MKVToolNix-98.0-macos-arm-b001-smart-build.dmg` | `e6df980b04` | — | — | First smart-build with dep caching |
| b002 | arm | feature | 2026-04-13 13:27 | strip-dylibs | `MKVToolNix-98.0-macos-arm-b002-strip-dylibs.dmg` | `b233b9f898` | — | — | Strip debug symbols from dylibs |
| b003 | arm | feature | 2026-04-13 13:46 | qt-6.10.2 | `MKVToolNix-98.0-macos-arm-b003-qt-6.10.2.dmg` | `c00eca1c77` | — | — | Qt version bump to 6.10.2 |
| b004 | arm | feature | 2026-04-13 14:22 | reduce-qt-modules | `MKVToolNix-98.0-macos-arm-b004-reduce-qt-modules.dmg` | `d9f470c0b4` | — | — | Drop unused Qt modules |
| b005 | arm | feature | 2026-04-13 19:11 | fix-qt-version-mismatch | `MKVToolNix-98.0-macos-arm-b005-fix-qt-version-mismatch.dmg` | `b91b38474f` | — | — | Qt version reconciliation attempt 1 |
| b006 | arm | feature | 2026-04-13 19:29 | fix-qt-version-mismatch | `MKVToolNix-98.0-macos-arm-b006-fix-qt-version-mismatch.dmg` | `759f42b331` | — | — | Qt version reconciliation attempt 2 |
| b007 | arm | feature | 2026-04-14 09:53 | build-cache-architecture | `MKVToolNix-98.0-macos-arm-b007-build-cache-architecture.dmg` | `6efe25135e` | — | — | Build cache redesign |
| b008 | arm | feature | 2026-04-14 09:58 | build-cache-architecture | `MKVToolNix-98.0-macos-arm-b008-build-cache-architecture.dmg` | `e48bcdba81` | — | — | Build cache redesign iteration |
| b009 | arm | feature | 2026-04-14 12:25 | build-optimization | `MKVToolNix-98.0-macos-arm-b009-build-optimization.dmg` | `72b86a526d` | — | — | General build optimization |
| b010 | arm | main | 2026-04-14 15:50 | main | `MKVToolNix-98.0-macos-arm-b010-main.dmg` | `e61b7b4c2a` | — | **retracted: v98.0-b2026.04.1** | First main release; retracted due to Homebrew leak crash |
| b011 | arm | feature | 2026-04-15 00:53 | fix-qt-remove-pkg-config | `MKVToolNix-98.0-macos-arm-b011-fix-qt-remove-pkg-config.dmg` | `4566f85ec8` | — | — | Homebrew leak fix attempt 1 |
| b012 | arm | feature | 2026-04-15 01:54 | fix-qt-force-bundled-libs | `MKVToolNix-98.0-macos-arm-b012-fix-qt-force-bundled-libs.dmg` | `591603aed5` | — | — | Homebrew leak fix attempt 2 |
| **b013** | arm | main | 2026-04-15 02:23 | fix-qt-homebrew-leak | `MKVToolNix-98.0-macos-arm-b013-fix-qt-homebrew-leak.dmg` | **`556382284a`** | — | **v98.0-b2026.04.3 → apple-silicon.dmg** | **Current shipped release** (SHA-verified match) |
| b014 | arm | experimental | 2026-04-19 13:52 | experimental-upstream-main | `MKVToolNix-98.0-macos-arm-b014-experimental-upstream-main.dmg` | `612192fe73` | `logs/MKVToolNix-98.0-macos-arm-b014-experimental-upstream-main.log` | — | Experimental upstream/main tracking |
| b015 | arm | experimental | 2026-04-19 | (unknown) | **missing** | — | — | — | No preservation; likely aborted/failed during experimental work |
| b016 | arm | experimental | 2026-04-19 | (experimental) | **missing** | — | — | — | Per memory: *"b016 without helper lost both patches"* — broken test build, not preserved |
| b017 | arm | experimental | 2026-04-19 17:58 | exp-audio-fix | `MKVToolNix-98.0-b017-exp-audio-fix-macos-apple-silicon.dmg` | `520a649a31` | `logs/MKVToolNix-98.0-b017-exp-audio-fix-macos-apple-silicon.log` | — | #6209 audio default fix testing (alt naming) |
| b018 | arm | experimental | 2026-04-19 18:49 | exp-browse-default | `MKVToolNix-98.0-b018-exp-browse-default-macos-apple-silicon.dmg` | `01e570f929` | `logs/MKVToolNix-98.0-macos-arm-b018-experimental-macos-browse-default.log` | — | #6211 original (pre-redirect) hardcoded browse default |
| b019 | arm | main | 2026-04-20 21:38 | main | **deleted** | — | `logs/MKVToolNix-98.0-macos-arm-b019-main.log` | — | **Contaminated build** (tarball had yesterday's experimental content); deleted 2026-04-21 |
| b020 | arm | fork | 2026-04-21 13:09 | 6211-audio-browse-dir (hash `23818e`) | `MKVToolNix-98.0-macos-arm-b020-fork-6211-audio-browse-dir-23818e.dmg` | `(see .sha256)` | `build-fork-6211-audio-browse-dir-b020-23818e.log` | — | **First `tools/build-fork.sh` build.** Worktree `fix/6211-audio-browse-dir` + experimental Qt 6.11.0 / zlib 1.3.2 overlay. Ad-hoc signed. VERSIONNAME `99pre-exp-6211-audio-browse-dir-b020-23818e`. 3 prior attempts failed (no autogen, missing submodules, codesign cert missing + dual Qt); fixes applied to script before this run. Fork builds never copy to release/. |
| b021 | arm | fork | 2026-04-22 05:16 | 6211-audio-browse-dir (hash `f3bbd9`) | `MKVToolNix-98.0-arm-b021-fork-6211-audio-browse-dir-f3bbd9.dmg` | `(see .sha256)` | `build-fork-6211-audio-browse-dir-b021-f3bbd9.log` | — | **Refactor per mbunkus's review on PR #6213** — extracted the 3-line inline load block into `loadLastProgramRunnerAudioDir(reg)` helper matching the `loadXyz(reg)` pattern. Ad-hoc signed. VERSIONNAME `99pre-exp-6211-audio-browse-dir-b021-f3bbd9`. 6/6 walkthrough tests passed. Commit amended (`b7052b4a8` → `d64df53870`) and force-pushed to PR #6213. First DMG with new naming convention (dropped `-macos-` from local builds). |

## INTEL (x86_64) builds

| # | Arch | Type | Date | Branch/Slug | DMG | SHA256 | Log | Release | Notes |
|---|------|------|------|-------------|-----|--------|-----|---------|-------|
| b001 | intel | main | 2026-04-14 11:40 | main | `MKVToolNix-98.0-macos-intel-b001-main.dmg` | `82ac792199` | — | likely **retracted: v98.0-b2026.04.1** | First main intel release (same day as arm b010) |
| b002 | intel | main | 2026-04-14 16:08 | main | `MKVToolNix-98.0-macos-intel-b002-main.dmg` | `207b736e58` | — | — | Post-retraction main iteration |
| b003 | intel | feature | 2026-04-15 00:52 | fix-qt-force-bundled-libs | `MKVToolNix-98.0-macos-intel-b003-fix-qt-force-bundled-libs.dmg` | `e629d5ce9b` | — | — | Homebrew leak fix attempt (intel) |
| b004 | intel | feature | 2026-04-15 02:09 | fix-qt-remove-pkg-config | `MKVToolNix-98.0-macos-intel-b004-fix-qt-remove-pkg-config.dmg` | `be43cb47f0` | — | — | Homebrew leak fix iteration (intel) |
| **b005** | intel | main | 2026-04-15 03:13 | fix-qt-homebrew-leak | `MKVToolNix-98.0-macos-intel-b005-fix-qt-homebrew-leak.dmg` | **`baa706c301`** | — | **v98.0-b2026.04.3 → intel.dmg** | **Current shipped intel release** (SHA-verified match) |

## Summary

- **Total builds preserved:** 22 (17 arm + 5 intel)
- **Missing from preservation:** 3 (arm b015, b016, b019)
- **Currently shipped:** arm b013 + intel b005 (both verified by SHA256 match against GitHub release v98.0-b2026.04.3 assets)
- **Retracted:** v98.0-b2026.04.1 (arm b010 + intel b001 probable — Homebrew leak crash; assets removed from GitHub)

## Notes on preservation gaps

Three builds without artifacts in `build/`:

- **b015 (arm, 2026-04-19):** Undocumented. Counter advanced but no DMG preserved. Likely an aborted build during experimental work on that date.
- **b016 (arm, 2026-04-19):** Built without the staging helper that ensures patches survive — effectively a broken build, not retained.
- **b019 (arm, 2026-04-20):** Built on main branch with yesterday's contaminated tarball as source. DMG had experimental content but main-branch filename — misleading artifact. Deleted 2026-04-21 during cleanup.

## Provenance methodology

Release mapping is verified by **SHA256 equality** between the build's `.sha256` file and the published GitHub release asset's SHA256. "Likely retracted" entries are inferred from date proximity to a retracted release; assets no longer exist on GitHub to verify against.

## Maintenance

For now this doc is manually maintained. Append a row for each new build completion. Candidate automation (future): `build-local.sh` appends a row via `>>` after successful verification.

Column conventions:
- Use `—` for not-applicable or empty cells (not blank)
- Bold a build number (`**b013**`) to mark its status as currently-shipped
- SHA256 is first 10 chars only; full value lives in the paired `.sha256` file

## Build runs after 2026-04-22 (summary)

Builds b022–b032 on ARM were development-track and fork builds rather than main-branch production builds. High-level purpose:

| # | Type | Purpose |
|---|------|---------|
| b022 | feature | LTO + `-Os` + aggressive-strip combined (--full rebuild) — initial size measurement |
| b023 | feature | Strip-only isolation test — measured against b022 to attribute savings |
| b024 | feature | LTO + `-Os` isolation test — confirmed LTO+`-Os` carries the full ~1.1 MB DMG / ~3.5 MB app reduction; aggressive-strip retired as no-op |
| b025 | main | Production build run on `main` |
| b026 | feature | Build-system improvement run |
| b027 | experimental | First DMG with sentinel manifest sidecars — initial validation of the experimental-build architecture |
| b028 | experimental | Portability-fix end-to-end verification — drift-handling against the existing dep cache |
| b029 | experimental | Canonical baseline — pure upstream/main + Qt 6.11.0, no wrapper patches; established the pre-optimization measurement reference for this Qt version |
| b030 | experimental | LTO+`-Os` measurement against b029 — −0.90 MB DMG / −2.63 MB app at Qt 6.11.0 |
| b031 | experimental | Remove-PrintSupport measurement against b029 — Qt rebuilt without PrintSupport, −0.12 MB DMG / −0.48 MB app |
| b032 | experimental | Integration measurement — both LTO+`-Os` and remove-PrintSupport stacked — −1.05 MB DMG / −3.11 MB app, additive (no interaction) |

Per-build provenance (DMG SHA256, source refs, deps used, configure args hash, host specs, build timing, verification results) lives in the `.dmg.manifest.json` sidecars alongside each DMG in `build/`. Experimental-build manifests in particular capture the full reproducibility chain.

Builds b027 onward used `tools/build-fork.sh` (renamed to `tools/build-exp.sh` on 2026-05-06); their DMG filenames in `build/` retain the historical `b{NNN}-fork-{slug}-{hash}` form.

The optimization patches that landed in production from these measurements are documented in `PATCHES.md`.

## Naming convention change — 2026-04-22

On 2026-04-22 the local-build DMG naming convention dropped the redundant `-macos-` segment. Existing 23 DMGs in `build/` were renamed accordingly and `.sha256` sidecars regenerated (hash values unchanged). Rows for b001-b020 above retain their **original-at-creation** filenames for historical accuracy; the actual files on disk now use the new convention. SHA256 (first 10 chars in the DMG column would match the sidecar file content) remains the authoritative provenance anchor regardless of filename. See `CHANGELOG.md` entry dated 2026-04-22 for full details.
- Date format: `YYYY-MM-DD HH:MM` local time
