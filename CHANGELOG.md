# Changelog

## Size optimization: LTO + -Os for mkvtoolnix (2026-05-06)

**Production builds now ship smaller binaries.** Adds
`patches/mkvtoolnix-size-opt.patch`, applied automatically by
`build-local.sh`. The patch enables ThinLTO (`-flto=thin`) and
optimize-for-size (`-Os`) for the mkvtoolnix compile only — deps
continue building at the existing `-O2`.

**Measured impact** (against an unpatched Qt 6.11.0 baseline, fork-build
measurement on ARM64):

| | Baseline | With LTO+-Os | Delta |
|---|---|---|---|
| DMG | 36.68 MB | 35.78 MB | −0.90 MB (−2.44%) |
| App on disk | 79.87 MB | 77.24 MB | −2.63 MB (−3.29%) |

Combined with the existing PrintSupport-removal patch: −1.05 MB DMG /
−3.11 MB app vs the unpatched Qt 6.11 baseline. The two optimizations
are additive — no interaction.

**No functional change**, just smaller binaries. App still launches and
runs all features. ThinLTO is fast incremental LTO; `-Os` chooses
size-favoring optimization paths over speed-favoring ones. Speed impact
is at the noise floor for this codebase.

---

## Build wrapper architecture overhaul (2026-05-06)

**Major reworking of the experimental build wrapper, plus portability
hardening for both production and experimental wrappers.** Closes
several silent-failure modes and gives every fork build a verifiable
provenance trail.

`tools/build-fork.sh` (experimental builder) gained an architecture for
cache integrity and build provenance:

- **Cache provenance manifests.** Each promoted dep tarball in
  `~/opt/proven-experimental/<arch>/` now ships with a
  `<package>.tar.gz.manifest.json` sidecar capturing `spec_name`,
  `source_sha256`, `configure_args_hash`, `patch_state_hash`, build
  date, dylib count, and non-identifying host info (CPU brand, RAM,
  macOS version, clang version, SDK version). Read at restore time;
  cache entries without manifests trigger a `WARN` since their
  provenance is unknown.
- **Cache manifest validation.** Restore now refuses on critical
  mismatch (`schema_version`, `spec_name`, `package`, `source_sha256`)
  rather than restoring blindly. Drift on advisory fields
  (`configure_args_hash`, `patch_state_hash`) is reported but doesn't
  refuse — those are approximations.
- **Stable `_qt_args_hash`.** Awk-state-machine extraction scoped to
  the `args=()` block of `build_qt`, with whitespace normalization
  before sort+sha. Stable across reformatting; no longer folds in
  cmake build/install command lines.
- **`patch_state_hash`.** Separate field from `args_hash`; hashes the
  concatenated content of `patches/qt-patches/*.patch`. Catches
  patch-edit drift that `args_hash` alone misses.
- **`_json_str` escape correctness.** Fixes a subtle escape bug that
  produced syntactically valid JSON which round-tripped to wrong
  values. Documented test (xxd byte dumps + `json.loads` round-trip)
  in the function comment.
- **DMG sidecar manifests.** Every successful fork build writes
  `<dmg>.manifest.json` next to the DMG capturing wrapper + fork
  source refs, patches applied (with SHAs), deps used and their cache
  origins, configure args hash, host specs, build timing, and
  verification results. Diffing two manifests immediately surfaces
  what changed between builds.
- **Opt-in `--rebuild-deps` flag.** Without it, missing cache entries
  hard-fail with explicit instructions (preserves cache-only
  smart-restore semantics for fast iteration). With it, missing deps
  are added to upstream's `build.sh` target dispatcher and built
  fresh, then promoted with provenance manifests.
- **`config/config.fork.local.sh` (NEW).** Fork-build config separate
  from production's `config.local.sh`. Mirrors signing, threads, and
  optimization flags but omits the QTVER pin so fork builds defer to
  the source's `specs.sh`. Production build path is unchanged.

**Portability hardening (both `build-local.sh` and `tools/build-fork.sh`):**

- All standard-tool invocations switched from absolute paths
  (`/usr/bin/awk`, etc.) to `command <tool>`. Apple has historically
  moved tools between macOS releases (`cat` lives at `/bin`, not
  `/usr/bin`); fixed-path invocations break silently when a tool
  moves. `command` bypasses shell aliases AND functions and uses PATH
  lookup.
- **Startup tool probe.** Each script now enumerates its required
  external tools and fails fast at startup with the missing tool's
  name if any are absent from PATH. Self-documenting, prevents
  surprise mid-build failures.
- **BSD-find probe.** Verifies `find -perm +111` works at startup.
  Catches homebrew `gfind` shadowing BSD find.

**Other fixes:**

- `_patch_state_hash` now uses the correct `/bin/cat` path (was
  silently hashing empty input due to a wrong absolute path). The
  `2>/dev/null` suppression that hid the bug is dropped so future
  failures of this kind are loud rather than silent.
- `TARGET` / `SRCDIR` env overrides preserved across upstream's
  `config.sh` source — fixes the silent dep-tree mix-up when a user
  points `TARGET=/Volumes/Fast/opt`.
- `_validate_dep_manifest` exit captured via `if/else` rather than raw
  `$()` substitution under `set -e` — the function's deliberate
  non-zero return values (1=REFUSE, 2=DRIFT) no longer fatal-exit.
- `tools/build-fork.sh` workspace wipe now preserves `staging/` for
  ad-hoc dep archives alongside `proven/`, `proven-experimental/`,
  `source/`.

---

## Trust model hardening + README restructure (2026-04-29)

**Supply-chain hardening — second layer.** Builds on the 2026-04-25
tarball-signature work by extending verification across the full chain
from upstream tag to release artifact.

- `build-local.sh` now verifies the upstream **release tag's GPG
  signature** against the pinned mbunkus key before any work, and
  **SHA256-verifies each package** restored from the proven cache.
- `.github/workflows/build.yml` gains a versioned cache key (busts on
  version, patches, or config-overlay change) and a **GitHub
  build-provenance attestation** step that runs on tag-push releases.
  CI-built (Apple Silicon) DMGs published from now forward will have
  attestations verifiable with `gh attestation verify`.
- README restructured: download-first, with a single **Trust & install**
  section. Per-release table with direct download links retained.
- New `docs/trust-model.md` — full trust chain, threat model,
  verification commands, and a reproduce-yourself off-ramp for users
  who don't want to trust this repo.
- New `tools/check-upstream-tag-signing.sh` — precondition probe that
  verifies recent upstream tags are still signed by the pinned key.
  Safe to run anytime.

**Why:** before this, `specs.sh` and the dependency hashes inside it
were rooted in Codeberg integrity alone — a Codeberg compromise would
have been undetectable by the build system. Pinning to mbunkus's key
extends trust back to upstream identity. Build-provenance attestation
extends it forward to the published artifact (CI path only;
locally-built artifacts inherit the upstream half but not the
attestation).

---

## OpenPGP verification of upstream tarball (2026-04-25)

**Supply-chain hardening:** every build now verifies the upstream
`mkvtoolnix-${VERSION}.tar.xz` against an OpenPGP signature published by
[Moritz Bunkus](https://www.bunkus.org/) before the build script runs.

- Added `tools/mbunkus-pubkey.asc` — Moritz Bunkus's full public key,
  fetched from `https://bunkus.org/gpg-pub-moritzbunkus.txt`. Primary
  fingerprint `D9199745B0545F2E8197062B0F92290A445B9007` cross-verified
  on 2026-04-25 against four independent channels (bunkus.org,
  Codeberg, keys.openpgp.org, keyserver.ubuntu.com).
- Added `tools/mbunkus-fingerprint.txt` — pinned primary FP. Build
  script verifies the embedded `.asc` matches this before trusting it.
- `build-local.sh` pre-flight: cross-checks pinned FP, downloads
  `.tar.xz.sig` if missing, verifies signature using a temporary
  keyring (no user-keyring touch), hard-fails with a remediation
  message on any failure.
- Added `.github/workflows/verify-mbunkus-key.yml` — monthly cron job
  cross-checks the pinned fingerprint against three independent
  sources. Email notification on drift; never auto-updates.
- Added `docs/tarball-verification.md` — full guide with sequence
  diagrams, threat model, and refresh procedure.
- Added `tools/README.md` — provenance and operations notes.

**Why:** upstream's `packaging/macos/build.sh` does not checksum or
verify the mkvtoolnix tarball (`build_package /literal-path` mode
bypasses `retrieve_file`'s checksum step). That gap allowed the
2026-04-20 contamination incident; this closes it for both accidental
local replacement and (the stronger guarantee) a hypothetical
`mkvtoolnix.download` server compromise.

---

## Fork/experimental build tooling + DMG naming cleanup (2026-04-22)

**Fork build tooling:**
- Added `tools/build-fork.sh` — compiles MKVToolNix from a worktree source directly, bypassing the production tarball pipeline. Handles proven + experimental dep overlay (Qt 6.11.0, zlib 1.3.2), injects a dynamic `VERSIONNAME` for in-app build identification, verifies a caller-specified symbol is present in the binary before reporting success, and writes exclusively to `build/` (never `release/`). Created in support of the first PR-style upstream contribution, PR [#6213](https://codeberg.org/mbunkus/mkvtoolnix/pulls/6213).

**DMG naming convention (local dev only):**
- Local build DMG filenames dropped the redundant `-macos-` segment. This wrapper only builds for macOS; the token added nothing. New pattern: `MKVToolNix-{ver}-{arch}-b{NNN}-{suffix}.dmg`.
- Release DMGs in `release/` and on GitHub keep `-macos-apple-silicon` / `-macos-intel` for end-user clarity.
- Existing 23 DMGs in `build/` renamed to new convention; `.sha256` sidecars regenerated (hash values unchanged — SHA256 is a content hash).
- `build-local.sh` and `tools/build-fork.sh` updated to match.

**Upstream contribution path extended:**
- Filed PR [#6213](https://codeberg.org/mbunkus/mkvtoolnix/pulls/6213) upstream for issue [#6211](https://codeberg.org/mbunkus/mkvtoolnix/issues/6211) (audio-file browse dialog default directory). First PR-style contribution from `corticalcode`; prior work was filed as issues and implemented by mbunkus. (Subsequently integrated into `upstream/main` as commit [`d64df538`](https://codeberg.org/mbunkus/mkvtoolnix/commit/d64df53870cadd1870a1029a065be3715134679f) on 2026-04-22; issue #6211 closed.)

---

## Build-history index + housekeeping (2026-04-20 / 2026-04-21)

**Documentation:**
- Added `docs/build-history.md` — complete DMG preservation index for all arm + intel builds with provenance, SHA256 mapping, and release status. 21 builds cataloged.

**Repo hygiene:**
- Added SHA256 checksums for proven cache tarballs in `proven/{arm,intel}/`.
- `.gitignore` trimmed; some patterns migrated to per-clone `.git/info/exclude`. Public repo's `.gitignore` is now narrower and project-universal.
- Added `.cz.toml` for commitizen commit-message validation.

---

## Housekeeping & tooling (2026-04-19)

**Release management:**
- Retracted [v98.0-b2026.04.1](../../releases/tag/v98.0-b2026.04.1) — both DMGs removed and replaced with a `RETRACTED.txt` marker explaining the Homebrew library-leak crash. Tag preserved for historical reference (still referenced in `PATCHES.md`).

**Documentation:**
- Added `proven/NOTICE.md` — third-party attribution for every library bundled into the proven dependency cache. Covers both `proven/arm/` and `proven/intel/`. Addresses GPL/LGPL source-availability and permissive-license attribution for repo-hosted compiled binaries.
- README: replaced the download bullet list with a release table showing download links and sizes per architecture.
- README + `docs/build-workflow.md`: documented the shared `.build-counter-{arm,intel}` files — why they're tracked and how to reset on a fresh clone.

**Build-script guards:**
- `build-local.sh` now refuses `--promote` on any branch except `main` — prevents accidental `proven/` commits from experimental work (commit `cfdf450`).
- `build-local.sh` now skips the release-ready DMG copy on non-main branches — prevents experimental builds from leaving a file in `release/` that looks like a shippable artifact (commit `22061b4`).

**Upstream cross-references:**
- `PATCHES.md` now links each build patch to its upstream Codeberg issue: [#6205](https://codeberg.org/mbunkus/mkvtoolnix/issues/6205), [#6206](https://codeberg.org/mbunkus/mkvtoolnix/issues/6206), [#6207](https://codeberg.org/mbunkus/mkvtoolnix/issues/6207), [#6208](https://codeberg.org/mbunkus/mkvtoolnix/issues/6208) — all closed `res:fixed/implemented`, `fixed-in-version/99.0`. Local patches remain active until 99.0 releases.

**CI & security scanning:**
- Added explicit `permissions:` block to the CI workflow — resolves CodeQL alert #1 (commit `5bff010`).
- Added gitleaks configuration for custom secret and privacy scanning (public `bc3da08`, private `eb119a9`).
- Tidied `.gitignore` (commits `82e5b19`, `414b027`).

---

## Build System: LFS On-Demand (2026-04-15)

Proven dependency cache is now opt-in. Cloning the repo no longer downloads ~534 MB of pre-built dependency archives.

**What changed:**
- Added `.lfsconfig` with `fetchexclude = proven/**` — clones are now ~1 MB
- New `--restore-cache` flag: pulls pre-built deps from LFS for your architecture, copies to local build cache, cleans up repo
- New `--cleanup-lfs` flag: restores `proven/` to pointer files and prunes LFS cache (for existing clones)
- `--promote` now cleans up repo LFS objects after committing
- `cleanup_repo_lfs` uses bounded `dd`-based LFS header detection (safe on large binaries)
- Failed `git lfs pull` is caught and repo is restored to clean pointer state
- `restore_from_proven` validates all packages exist before untarring (no partial restore)
- CI workflow updated to work with `.lfsconfig` (explicit LFS restore instead of `lfs: true`)

**New flags:**
- `--restore-cache` — pull proven deps from LFS to local cache and clean up (no tag required)
- `--cleanup-lfs` — restore proven/ to pointer files and prune LFS cache (no tag required)

**Documentation:**
- New `docs/build-workflow.md` with Mermaid flowcharts covering all build modes
- Updated `docs/proven-cache.md` and `README.md` with `--restore-cache` workflow
- Existing clone cleanup instructions (scripted and manual)

**Known limitation:** On clones that predate `.lfsconfig`, `--cleanup-lfs` cannot automatically restore pointer files due to a Git index optimization. The script detects this and prints manual fix instructions. See [docs/lfs-migration.md](docs/lfs-migration.md) for the one-time migration steps.

**Multi-agent review:** Three rounds of cross-provider review (Codex + Gemini) identified and fixed: function-before-define crash, unreliable pointer detection, single-arch cleanup, circular clone dependency, interrupted pull recovery, partial restore on stale cache, unbounded binary reads, documentation inconsistencies, and the Git index optimization that prevents automatic pointer restoration on existing clones.

---

## v98.0-b2026.04.3 (2026-04-15) — Current Release

Critical fix for Homebrew library leak that caused DYLD crashes on launch.

**What was broken:** Qt was linking against Homebrew system libraries (double-conversion, pcre2, zstd, libpng, md4c, freetype) instead of its bundled copies. Any user without those same Homebrew packages would get a "library not loaded" crash. All previous builds were affected.

**Fix (belt and suspenders):**
- Removed `-force-pkg-config` and `-pkg-config` from Qt configure, restoring Qt 6's default macOS behavior where Homebrew prefixes are excluded from library search paths
- Added `-force-bundled-libs` to force Qt's bundled third-party libraries, and `-no-feature-zstd` to disable zstd (not bundled by Qt, falls back to zlib)

**Downloads:**
- Apple Silicon (arm64): `MKVToolNix-98.0-macos-apple-silicon.dmg` — 77.3 MB app, 36 MB DMG
- Intel (x86_64): `MKVToolNix-98.0-macos-intel.dmg` — 81.9 MB app, 38 MB DMG

**Build system improvements:**
- Post-build Homebrew/external library leak detection (scans all dylibs for non-system references)
- App size verification now uses actual file bytes (decimal MB) to match Finder
- Build timing (start, finish, elapsed) added to build reports
- Build logs copied to `logs/` directory with build number
- Internal DMG filename reordered: build number before branch name for chronological sorting
- Workspace cleanup now includes compile directory to prevent stale build failures
- Output directories renamed: `dist/` → `build/` (internal) + `release/` (clean-named)

**Verified:** Tested in a clean virtual machine — previous builds crash on launch, updated builds run without issues.

**Filed upstream:** [Codeberg #6208](https://codeberg.org/mbunkus/mkvtoolnix/issues/6208)

**Upstream news:** Patches #6205, #6206, #6207 (Qt6 cmake install, debug symbol stripping, cmark optimization) were merged into upstream MKVToolNix v99.0.

**Other improvements:**
- CI workflow updated: CalVer tagging, `apple-silicon` filename convention, leak detection in verification
- DMG release filenames standardized to `apple-silicon` / `intel`

**Reported by:** Adam, Ryu67, and Vek239 on the MKVToolNix forum.

---

## v98.0-b2026.04.2 (2026-04-14)

Ad-hoc code signing for macOS Sequoia 15.1+ compatibility. Both Apple Silicon and Intel builds updated.

**Changes:**
- App is now ad-hoc signed (`SIGNATURE_IDENTITY="-"`) which should restore the "Open Anyway" flow on macOS Sequoia 15.1+ where completely unsigned apps are blocked
- Previously, users on Sequoia had no way to open the app through normal macOS UI

---

## v98.0-b2026.04.1 (2026-04-14)

> ⚠️ **RETRACTED 2026-04-19** — this build crashes on launch unless specific Homebrew packages are present. Both DMG assets have been removed from the GitHub release. Use [v98.0-b2026.04.3](../../releases/tag/v98.0-b2026.04.3) instead. See `proven/NOTICE.md`, this file's Housekeeping entry for 2026-04-19, and upstream issue [#6208](https://codeberg.org/mbunkus/mkvtoolnix/issues/6208) for the full root cause.

First combined Apple Silicon + Intel release with optimized builds.

**Downloads:**
- Apple Silicon (arm64): 72 MB app, 31.9 MB DMG
- Intel (x86_64): 86.6 MB app, 39 MB DMG

**Built with:** Qt 6.10.2, Boost 1.88.0, macOS 13+ deployment target.

**Active patches (6):**
- `qt6-cmake-install.patch` -- Qt6 cmake install fix
- `specs-updates.patch` -- Qt 6.10.2 bump + zlib URL fix
- `remove-printsupport.patch` -- drop unused Qt module
- `strip-dylibs.patch` -- strip debug symbols from dylibs
- `cmark-release-build.patch` -- CMAKE_BUILD_TYPE=Release for cmark
- `qt-patches/001-fix-arm-yield-declaration.patch` -- ARM arm_acle.h include for Qt

**Build system improvements:**
- Ad-hoc code signing for macOS Sequoia 15.1+ compatibility
- Proven dependency cache with per-architecture storage (Apple Silicon / Intel)
- Compiler optimization (-O2) and linker dead-stripping for all dependencies
- Comprehensive post-build verification (Qt version, architecture, duplicate dylibs, size)
- Build logging, reporting, and error trapping
- Dynamic EXPECTED_PACKAGES derivation from specs.sh

**Note on earlier releases:** During development, multiple intermediate releases (r1 through r5 for ARM, r1 for Intel) were published and subsequently pulled as the build process was refined and optimized. Only this final verified release is published. Previous builds are available on request.

---

## Development History (2026-04-13 to 2026-04-14)

### Build optimization (2026-04-14)

- Added `-O2` to CFLAGS/CXXFLAGS — autotools deps were building at `-O0`
- Added `-Wl,-dead_strip` to LDFLAGS — removes unreachable code at link time
- Added `-DCMAKE_BUILD_TYPE=Release` to cmark build
- Restored `qt-patches/001-fix-arm-yield-declaration.patch` — Qt 6.10.2 does NOT include the arm_acle.h fix (was incorrectly retired; exposed by `--full` rebuild)
- Size impact: App 78.5 -> 72.0 MB (8%), DMG 33.9 -> 31.9 MB (6%)

### Script hardening (2026-04-14)

- Multi-reviewer audit identified 33 issues across correctness, portability, and robustness
- All 7 P1 and 14 P2 issues fixed: set -e safety, NULL_GLOB guards, alias isolation, clone tag verification, promote validation, verification hardening
- Shell interpreter guard, improved error trapping, INT/TERM signal handling

### Build cache architecture (2026-04-14)

- Proven cache system with per-architecture storage
- Complete workspace wipe before every build
- Smart restore: builds only mkvtoolnix when all deps are cached (~15 min vs ~1-3 hrs)
- Atomic promotion with Git LFS archiving
- Comprehensive post-build verification

### Qt version mismatch bug (2026-04-13)

Builds b003 and b004 claimed Qt 6.10.2 but were built against Qt 6.10.0 due to a QTVER mismatch. A stale Qt 6.10.0 build directory masked the error on ARM. Discovered when the Intel build (clean machine) failed correctly. Root cause: Qt version specified in multiple locations with no validation. Fixed with pre-build verification and workspace wipe.

### Initial builds (2026-04-13)

- b001: First successful ARM build (Qt 6.10.0, 84.8 MB app)
- b002: Added debug symbol stripping (78.9 MB app)
- b003-b004: RETRACTED — Qt version mismatch
- b005: Duplicate dylib bug (101.8 MB app) — retracted
- b006-b008: Clean builds with build cache architecture (78.5 MB app)
