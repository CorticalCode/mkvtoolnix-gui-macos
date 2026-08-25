# Build Patches — What, Why, and How

Living document tracking every modification made to build MKVToolNix on macOS (Apple Silicon and Intel), the problems encountered, and how they were resolved.

## Build status

**v101.0** built and verified (Apple Silicon + Intel). No dependency changes from v100 — upstream's `packaging/macos/specs.sh` is byte-identical between `release-100.0` and `release-101.0`, so Qt stays 6.11.1. The single active wrapper patch (**`mkvtoolnix-size-opt`**) still applies cleanly; zero Qt source patches. Restored from the proven cache; no promotion needed.

v100.0 built and verified (Apple Silicon + Intel). Only dependency change from v99: **Qt 6.11.0 → 6.11.1** (upstream #6277). The single active wrapper patch (**`mkvtoolnix-size-opt`**) still applies cleanly; zero Qt source patches. Full from-source rebuild — all deps + Qt 6.11.1 verified. Proven cache (arm) promoted to v100 deps.

v99.0 built and verified (Apple Silicon). Upstream `release-99.0` merged or superseded **7 of the 8** wrapper patches; only **`mkvtoolnix-size-opt`** (our ThinLTO/`-Os` optimization, no upstream equivalent) remains active, re-added after measuring it against the pure baseline (see "Active patch" + "Size progression"). release-99.0 also adds two macOS build dependencies the wrapper now tracks: `gnupg` (source-signature verification) and `shared-mime-info` (FreeDesktop MIME database, upstream #6248).

Previous release: **v98.0-b2026.04.3** (Apple Silicon + Intel). The build process uses a proven cache architecture with per-architecture storage: dependencies are compiled once, verified, and promoted to a cache. Subsequent builds restore from cache and only rebuild mkvtoolnix. See the "Build script fixes" section below for details.

## Size progression

| Build | DMG | App on disk | Qt actual | Notes |
|-------|-----|-------------|-----------|-------|
| b001 (baseline) | 34.9 MB | 84.8 MB | 6.10.0 | verified |
| b002 (+ strip dylibs) | 34.0 MB | 78.9 MB | 6.10.0 | verified |
| b003 (+ Qt bump) | 34.0 MB | 78.9 MB | **6.10.0** | RETRACTED — claimed 6.10.2 |
| b004 (+ no PrintSupport) | 33.9 MB | 78.4 MB | **6.10.0** | RETRACTED — claimed 6.10.2 |
| b005 (duplicate dylibs) | 42.8 MB | 101.8 MB | 6.10.2 | duplicate Qt dylibs — retracted |
| b006 (clean baseline) | 33.9 MB | 78.6 MB | 6.10.2 | verified |
| b007 (build-cache, full) | 33.9 MB | 78.6 MB | 6.10.2 | verified, full build |
| b008 (build-cache, restore) | 33.9 MB | 78.5 MB | 6.10.2 | verified, smart restore |
| b009 (+ O2, dead_strip) | 31.9 MB | 72.0 MB | 6.10.2 | ARM, verified, optimization flags |
| Intel b001 | 39.0 MB | 86.6 MB | 6.10.2 | Intel, verified, pre-optimization |
| **v99 rel001 (pure baseline)** | 28.57 MB | 79.15 MB | 6.11.0 | ARM, verified, zero wrapper patches (APFS+ULMO DMG now upstream) |
| **v99 rel002 (+ LTO/-Os)** | 27.49 MB | 76.50 MB | 6.11.0 | ARM, verified, −1.08 MB DMG / −2.65 MB app vs rel001 |
| **v100 rel003 (Qt 6.11.1)** | 24.8 MB | 74.8 MB | **6.11.1** | ARM, verified, full rebuild from source; Qt bumped to 6.11.1 |
| **v101 rel004 (source bump)** | 24.8 MB | 74.9 MB | 6.11.1 | ARM, verified, restored from proven cache; deps unchanged from v100 |

---

## Patches

v99.0 retired **7 of the 8** wrapper patches — upstream `release-99.0` merged or superseded them. One remains active: **`mkvtoolnix-size-opt`**, our ThinLTO/`-Os` optimization, which has no upstream equivalent and was re-added after measuring it against the pure baseline.

### Active patch — `mkvtoolnix-size-opt`

Adds `-flto=thin -Os` to `CXXFLAGS` (and `-flto=thin` to `LDFLAGS`) for the mkvtoolnix compile only, scoped inside `build_mkvtoolnix` (re-targeted for release-99.0's function). Dependencies keep building at `-O2`. Measured on ARM64 — v99 rel002 vs the pure rel001 baseline, identical restored deps so the only difference is the flags:

| | Baseline (rel001) | + LTO/-Os (rel002) | Delta |
|---|---|---|---|
| DMG | 28.57 MB | 27.49 MB | −1.08 MB (−3.78%) |
| App on disk | 79.15 MB | 76.50 MB | −2.65 MB (−3.35%) |
| `mkvtoolnix-gui` binary | 7.66 MB | 6.65 MB | −1.00 MB (−13.10%) |

No functional change; ThinLTO is fast incremental LTO and `-Os` favors size over speed (speed impact at the noise floor).

### Retired at v99.0 (7 patches)

Each was verified against the actual release-99.0 source before removal (reverse-applies clean = change present upstream; conflicts investigated individually). The detailed entries below are retained as historical record.

| Patch | Retirement evidence |
|-------|---------------------|
| `qt6-cmake-install` | Merged upstream (#6205, fixed-in 99.0); reverse-applies clean |
| `specs-updates` | Obsolete — Qt is 6.11.0 upstream; zlib.net 200 OK (mirror redirect moot) |
| `remove-printsupport` | Merged upstream; reverse-applies clean against release-99.0 |
| `strip-dylibs` | Merged upstream (#6206, fixed-in 99.0); `build_dmg` strips dylibs (build.sh) |
| `cmark-release-build` | Merged upstream (#6207, fixed-in 99.0); reverse-applies clean |
| `qt-fix-homebrew-leak` | Merged upstream (#6208, fixed-in 99.0); reverse-applies clean |
| `qt-patches/001-arm-yield` | Upstream ships `qt-patches/fix-qyieldcpu-yield-for-arm.patch` (same fix, same file) |

### Historical detail

### 1. Qt6 cmake install (`patches/qt6-cmake-install.patch`)

**File patched:** `packaging/macos/build.sh` line 373

**Problem:** The upstream `build_qt` function compiles Qt6 using `cmake --build` but then tries to install with `make DESTDIR=TMPDIR install`. Qt6's build system is fully cmake-based -- the Makefile install target doesn't work correctly for Qt6's module layout.

**Root cause:** Qt transitioned from qmake to cmake as its build system. The upstream MKVToolNix build script was written when `make install` still worked. Qt6's cmake build generates install rules that are only accessible via `cmake --install`.

**Fix:** Replace the install command in `build_qt`:
```
- build_tarball command "make DESTDIR=TMPDIR install"
+ build_tarball command "cmake --install . --prefix TMPDIR${TARGET}"
```

**Note:** Only the Qt-specific line (line 373) is patched. The generic `build_package` function (line 150) has the same `make install` pattern but it works fine for other cmake packages (cmark, etc.) because they generate proper Makefile install targets.

**Source:** MKVToolNix forum thread -- multiple users reported this fix for Qt6 builds.

**Upstream:** [Codeberg #6205](https://codeberg.org/mbunkus/mkvtoolnix/issues/6205) — filed 2026-04-14, closed `res:fixed/implemented`, `fixed-in-version/99.0`.

---

### 2. Specs updates (`patches/specs-updates.patch`)

**File patched:** `packaging/macos/specs.sh`

This patch combines two changes to the same file to avoid context conflicts when applied in sequence.

**2a. Dead zlib download URL**

**Problem:** Build fails at zlib step. `curl` downloads a 355-byte HTML error page. Checksum verification catches it.

**Root cause:** `https://zlib.net/zlib-1.3.1.tar.xz` returns 404. zlib removes old tarballs when new versions release.

**Fix:** Switch to GitHub releases mirror (same file, same checksum):
```
- https://zlib.net/zlib-1.3.1.tar.xz
+ https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.xz
```

**Shelf life:** Unnecessary when upstream bumps zlib or fixes the URL.

**Upstream:** Upstream has moved to zlib 1.3.2 (URL currently 200 OK on zlib.net as of 2026-04-19). Our 1.3.1 URL fix becomes moot when we retire patches at 99.0. The structural issue (zlib.net deletes old tarballs on every release) recurs — filing a switch to the GitHub release mirror would prevent recurrence. Not filed; low priority since mbunkus handles via version bumps.

**2b. Qt version bump to 6.10.2**

**Problem:** Qt 6.10.0 has a compilation bug on ARM (`__yield` without `arm_acle.h` include) and community-reported UI issues (progress bar, preferences truncation, pane resizing, macOS 26 rendering).

**Fix:** Bump Qt from 6.10.0 to 6.10.2 with updated download URL and SHA256 checksum. Note: Qt 6.10.2 does NOT include the `arm_acle.h` fix — the Qt source patch is still required (see section 5).

**Upstream:** Covered by mjuhasz [PR #6202](https://codeberg.org/mbunkus/mkvtoolnix/pulls/6202) (closed; equivalent work applied by mbunkus). Separate filing not needed.

---

### 3. Remove unused PrintSupport (`patches/remove-printsupport.patch`)

**File patched:** `packaging/macos/build.sh` (two locations)

**Problem:** Qt PrintSupport module (453 KB) is compiled and bundled in the app, but MKVToolNix has zero print functionality -- no references to `QPrinter`, `QPrintDialog`, or `QPrintPreview` anywhere in the source.

**Root cause:** The upstream Qt configure line doesn't explicitly exclude PrintSupport. It disables cups but not the broader print module.

**Fix:**
1. Add `-no-feature-printsupport` to the Qt configure arguments
2. Remove `PrintSupport*.dylib` from the dylib copy in `build_dmg`

**Verification:** Traced all Qt class imports in `src/mkvtoolnix-gui/` -- confirmed zero PrintSupport usage. Verified the module is absent from the built app bundle.

**Size impact:** 453 KB uncompressed, 138 KB compressed in DMG.

**Upstream:** Not yet filed. Lower priority — optimization/cleanup rather than a bug.

---

### 4. Strip debug symbols from dylibs (`patches/strip-dylibs.patch`)

**File patched:** `packaging/macos/build.sh` after line 512

**Problem:** Upstream strips the five mkv binaries but not the Qt shared libraries or plugins. Debug symbols in bundled third-party libraries add ~6 MB with no value in a distribution build.

**Root cause:** The upstream build was designed for a developer who could debug against these libraries.

**Fix:** Add `strip -x` after `fix_library_paths.sh` runs, targeting all dylibs in the app bundle. The `-x` flag removes local symbols (debug info) while preserving global symbols needed for dynamic linking.

**Why after fix_library_paths.sh:** Library path rewriting modifies the dylib binaries. Stripping before path fixup could remove relocation info needed by `install_name_tool`.

**Size impact:** 6 MB uncompressed (84.8 -> 78.9 MB), 0.9 MB compressed in DMG.

**Upstream:** [Codeberg #6206](https://codeberg.org/mbunkus/mkvtoolnix/issues/6206) — filed 2026-04-14, closed `res:fixed/implemented`, `fixed-in-version/99.0`.

---

### 6. cmark Release build type (`patches/cmark-release-build.patch`)

**File patched:** `packaging/macos/build.sh` (build_cmark function)

**Problem:** The `build_cmark` function calls cmake without `-DCMAKE_BUILD_TYPE`. CMake defaults to an empty build type with no optimization flags, so cmark compiles at `-O0`.

**Fix:** Add `-DCMAKE_BUILD_TYPE=Release` to the cmake arguments. This enables standard `-O2 -DNDEBUG` optimization.

**Upstream:** [Codeberg #6207](https://codeberg.org/mbunkus/mkvtoolnix/issues/6207) — filed 2026-04-14, closed `res:fixed/implemented`, `fixed-in-version/99.0`.

---

### 7. Fix Homebrew library leak in Qt build (`patches/qt-fix-homebrew-leak.patch`)

**File patched:** `packaging/macos/build.sh` (build_qt function args)

**Problem:** Qt links against Homebrew system libraries (double-conversion, pcre2, zstd, libpng, md4c, freetype) instead of its bundled copies. Users without those Homebrew packages get a DYLD crash on launch: `Library not loaded: /opt/homebrew/libdouble-conversion.3.dylib`.

**Root cause:** The upstream `build_qt` args include `-force-pkg-config -pkg-config`, which re-enables system library discovery on macOS. Qt 6 intentionally disables this on Darwin to avoid package-manager contamination, but the upstream build script overrides the safeguard. When Homebrew has matching `.pc` files or cmake config, Qt's configure finds and links against them instead of its bundled `qtbase/src/3rdparty/` copies.

**Fix (belt and suspenders):**
- Remove both `-force-pkg-config` and `-pkg-config`, restoring Qt 6's default macOS behavior where Homebrew prefixes are stripped from cmake's search paths
- Add `-force-bundled-libs` (forces Qt's bundled copies) and `-no-feature-zstd` (zstd is not bundled by Qt; falls back to zlib compression)

**Scope:** Every build from b001 through b010 (ARM) and b001-b002 (Intel) was affected. Not caught because testing was on the build machines which have the same Homebrew packages.

**Reported by:** Adam, Ryu67, and Vek239 on the MKVToolNix forum, 2026-04-15.

**Upstream:** [Codeberg #6208](https://codeberg.org/mbunkus/mkvtoolnix/issues/6208) — filed 2026-04-15, closed `res:fixed/implemented`, `fixed-in-version/99.0`.

---

### 8. mkvtoolnix size optimization (`patches/mkvtoolnix-size-opt.patch`)

**File patched:** `packaging/macos/build.sh` — the `build_mkvtoolnix` function (around line 422).

**Problem:** mkvtoolnix's binaries inherit only the global `-O2` from `config.local.sh`. Adding `-flto=thin` (ThinLTO) and `-Os` (optimize for size) shrinks the compiled binaries materially without affecting deps. Deps (Qt, Boost, FLAC, libogg, etc.) continue building at `-O2` as before — the flags are scoped to mkvtoolnix only.

**Fix:** Save `CXXFLAGS` / `LDFLAGS` before `build_configured_mkvtoolnix`, append `-flto=thin -Os` to `CXXFLAGS` and `-flto=thin` to `LDFLAGS`, restore after. The flags must be set BEFORE `build_configured_mkvtoolnix` runs because autoconf bakes `USER_CXXFLAGS` / `USER_LDFLAGS` into `build-config` at configure time.

**Size impact** (verified on ARM64 against an unpatched Qt 6.11.0 baseline): −0.90 MB DMG / −2.63 MB app. Stacks additively with `remove-printsupport.patch`: combined effect was −1.05 MB DMG / −3.11 MB app.

**Speed impact:** at the noise floor for this codebase. ThinLTO is fast incremental LTO; `-Os` slightly de-prioritizes speed in favor of size. No perceptible regression in app launch or operation.

**Upstream:** Not filed. Speculative wrapper-side optimization; reversible if a future regression appears.

---

## Config overlay (`config/config.local.sh`)

**Not a patch** -- a config file sourced by the upstream build system.

- `SIGNATURE_IDENTITY="-"` -- ad-hoc code signing (required for macOS Sequoia 15.1+; no Apple Developer cert needed)
- `DRAKETHREADS=12` -- parallel build threads (default is 4, machine has 14 cores)
- `CFLAGS += -O2` -- standard release optimization (upstream sets no -O flag)
- `CXXFLAGS += -O2` -- same for C++
- `LDFLAGS += -Wl,-dead_strip` -- remove unreachable code at link time

**Size impact of optimization flags:** 78.5 -> 72.0 MB uncompressed (8% reduction), 33.9 -> 31.9 MB DMG (6% reduction).

---

## Build script fixes (in `build-local.sh`)

**Proven cache architecture:** Compiled dependency packages are stored in an architecture-specific proven cache (`~/opt/proven/arm/` or `~/opt/proven/intel/`). Each build wipes the workspace (everything under `~/opt/` except `proven/` and `source/`), restores from the proven cache for the current architecture, and only builds what's missing. If all deps are available, only mkvtoolnix is rebuilt (minutes instead of hours). A full rebuild from source is available with `--full`.

**Promotion workflow:** After a successful build and manual testing, `--promote` archives the current proven cache to Git LFS, atomically swaps in the new packages, and commits. Uses directory-swap for atomicity — interruption at any point leaves either old or new proven intact.

**Post-build verification:** Checks Qt version in binary, architecture of all binaries and dylibs, duplicate dylib scan, size sanity (60-95 MB range), Homebrew/external library leak detection, and bundle inventory. Each check fails closed: an absent input (no dylibs found, no `otool` output) is reported as a failure rather than a clean result. If verification does not pass, promotion is blocked **and** the release-named DMG is withheld — only the internal `build/` copy is written, for diagnosis.

**Pre-build verification:** QTVER/specs.sh consistency check (already existed), stale build directory cleanup for all dependencies (extended from Qt-only).

**EXPECTED_PACKAGES derived from specs.sh:** Package names are extracted dynamically from upstream's `spec_*` variables after sourcing specs.sh. Fails fast if any spec variable is missing (catches upstream renames). Eliminates version drift between specs.sh and the build script.

**cmark package rename:** Upstream names the cmark package `mtx-build.tar.gz`. Renamed to versioned `cmark-{version}.tar.gz` after build so version bumps invalidate the cache.

**DocBook XSL in cache:** Archived and restored alongside compiled packages.

**Error handling:** ERR trap prints line number and exit code on any command failure. Build output tee'd to timestamped log file. Build report with summary written after each build. Patch application distinguishes "already applied" from "genuinely broken."

**`command <tool>` throughout:** macOS zsh aliases `cp` to `cp -i`, and a Homebrew-first PATH can put GNU versions of `find`, `stat`, and `sed` ahead of the BSD ones. Calling tools via `command` bypasses aliases, and the scripts avoid flags that differ between the BSD and GNU implementations, so either set works.

**`git checkout -- .` before patching:** Ensures clean slate on re-runs.

---

## Qt source patches (`patches/qt-patches/`)

### 5. ARM `__yield` declaration (`qt-patches/001-fix-arm-yield-declaration.patch`)

**File patched:** `qtbase/src/corelib/thread/qyieldcpu.h` (applied to Qt source during extraction)

**Problem:** Qt6's `qyieldcpu.h` calls `__yield()` on ARM via `__has_builtin(__yield)`, but clang requires `<arm_acle.h>` to be included for the declaration. Without it, clang produces `-Werror,-Wimplicit-function-declaration`.

**Fix:** Add `#include <arm_acle.h>` guarded by `Q_PROCESSOR_ARM` and `__has_include`.

**History:** This patch was incorrectly retired on 2026-04-13 based on reports that Qt 6.10.2 included the fix upstream. Inspection of the actual Qt 6.10.2 source confirmed the fix is NOT present. The retirement went undetected because the proven cache contained pre-compiled Qt that was built WITH the patch — a smart-restore build never recompiled Qt, masking the issue. A `--full` rebuild on 2026-04-14 exposed the missing fix. The patch was restored.

**Lesson:** Never retire a patch based on release notes alone. Always verify the fix in the actual upstream source, and always test with `--full` (not smart-restore) to confirm.

**Upstream:** Qt project — not yet reported at bugreports.qt.io. Would need to be filed against Qt rather than MKVToolNix.

---

## Retired patches

7 of the 8 wrapper patches were retired at **v99.0** — see "Retired at v99.0 (7 patches)" above for the per-patch evidence; the detailed historical entries are preserved in that section.

`mkvtoolnix-size-opt` was *not* retired — it is our own ThinLTO/`-Os` optimization with no upstream equivalent. It was dropped from the pure rel001 baseline only to measure it in isolation, then re-added (rel002) once the delta was confirmed (−1.08 MB DMG / −2.65 MB app). It is the single active wrapper patch — see "Active patch" above.

---

## Issues investigated but not requiring patches

**`-no-rpath` crash:** Flagged in research as a common Qt6 build failure. Not present in v98.0 -- already removed upstream.

**Dependency build failures on ARM:** No ARM-specific issues. All dependencies build cleanly on Apple Silicon.

**macOS 13 deployment target:** No issues. Binaries built on macOS 26 with `MACOSX_DEPLOYMENT_TARGET=13` work correctly.

**Stale dependency URLs:** Checked all 17 URLs. Only zlib was dead (patched above). All others return 200.

---

## Issues discovered during development

### QTVER mismatch (discovered 2026-04-13)

**Severity:** High — caused mislabeled releases (r2, r3 removed)

**Problem:** specs-updates.patch changed specs.sh to download Qt 6.10.2, but QTVER in upstream config.sh remained 6.10.0. The build_qt function uses QTVER for the directory name after extraction. On ARM, a stale qt-everywhere-src-6.10.0 directory masked the error — builds appeared to succeed but used old Qt source. On Intel (clean machine), the directory didn't exist and the build correctly failed.

**Root cause:** Qt version is specified in multiple locations (specs.sh, config.sh, build-local.sh EXPECTED_PACKAGES) with no validation that they agree.

**Fix applied:**
- Set QTVER=6.10.2 in config.local.sh
- EXPECTED_PACKAGES derived dynamically from specs.sh
- Added pre-build check: verifies QTVER matches specs.sh, fails fast on mismatch
- Added stale Qt directory cleanup before extraction
- Added post-build check: confirms Qt version in the built binary

**Lesson:** Stale build artifacts can silently produce incorrect builds. Version changes must be validated end-to-end, not just at the download step. The build cache architecture now wipes the workspace before every build, preventing this class of error.
