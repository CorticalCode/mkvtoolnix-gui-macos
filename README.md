# mkvtoolnix-gui-macos

Unofficial, build-from-source macOS builds of [MKVToolNix GUI](https://mkvtoolnix.download/) for Apple Silicon and Intel — and a personal learning project in reproducible macOS packaging.

**Most people want the official builds.** As of 98.0, MKVToolNix again ships **signed, Apple-notarized** macOS DMGs — Apple Silicon, Intel, and universal — on the [official downloads page](https://mkvtoolnix.download/downloads.html#macosx) or via Homebrew (`brew install --cask mkvtoolnix-app`); both are packaged by Touchstone64 (see [Credits](#credits)). They install with no Gatekeeper workarounds, so prefer them.

This repo is a proof-of-concept that builds the full GUI from upstream source and publishes **unofficial, ad-hoc-signed** DMGs (not notarized). It's handy if you want to build it yourself, audit the process, or tinker with the build automation — shared as-is, no warranty, no SLA. (The MKVToolNix CLI tools are also on Homebrew via `brew install mkvtoolnix`.)

## Download

These are this repo's **unofficial** builds. For official **notarized** DMGs (recommended for most users), see the [official downloads page](https://mkvtoolnix.download/downloads.html#macosx).

| Date | Release | MKVToolNix | Apple Silicon | Intel |
|------|---------|:----------:|:-------------:|:-----:|
| 2026-07-05 | [v100.0-b2026.07.1](../../releases/tag/v100.0-b2026.07.1) | 100.0 | [DMG (25 MB)](../../releases/download/v100.0-b2026.07.1/MKVToolNix-100.0-macos-apple-silicon.dmg) | [DMG (28 MB)](../../releases/download/v100.0-b2026.07.1/MKVToolNix-100.0-macos-intel.dmg) |
| 2026-05-24 | [v99.0-b2026.05.1](../../releases/tag/v99.0-b2026.05.1) | 99.0 | [DMG (27 MB)](../../releases/download/v99.0-b2026.05.1/MKVToolNix-99.0-macos-apple-silicon.dmg) | [DMG (30 MB)](../../releases/download/v99.0-b2026.05.1/MKVToolNix-99.0-macos-intel.dmg) |
| 2026-04-15 | [v98.0-b2026.04.3](../../releases/tag/v98.0-b2026.04.3) | 98.0 | [DMG (34 MB)](../../releases/download/v98.0-b2026.04.3/MKVToolNix-98.0-macos-apple-silicon.dmg) | [DMG (36 MB)](../../releases/download/v98.0-b2026.04.3/MKVToolNix-98.0-macos-intel.dmg) |

All releases on the [Releases page](../../releases).

Not sure which? Apple menu → About This Mac. "Apple M_" = Apple Silicon, "Intel Core" = Intel.

Each DMG ships with a matching `.sha256` file:

```
shasum -a 256 -c MKVToolNix-100.0-macos-apple-silicon.dmg.sha256
```

DMGs produced by the CI workflow also carry a GitHub build-provenance attestation; the current release was built and uploaded manually, so it isn't attested. For a verified, notarized binary, use the [official builds](https://mkvtoolnix.download/downloads.html#macosx).

## Trust & install

These DMGs are ad-hoc signed, not Apple-notarized, so macOS blocks the first launch — Gatekeeper working as intended. Drag the app to Applications and open it; the first time, allow it one of two ways (don't pick "Move to Trash"):

- **System Settings → Privacy & Security:** click **Open Anyway**, then confirm.
- **Terminal:** `xattr -cr /Applications/MKVToolNix*.app`, then open normally.

This is the same trust model that applied to mbunkus's official DMGs before April 2026, and the same model MacPorts uses for its `+qtgui` variant. The DMG isn't notarized because notarizing would put my name on a chain of trust I can't honestly back — I'm not the upstream maintainer, I haven't audited Qt or boost or the other dependencies, and I'm in no position to vouch for them the way Developer ID signing implies.

What the build does verify: mbunkus's GPG signature on the MKVToolNix source tarball, his signed git tag on codeberg, SHA256 hashes on every dependency tarball, plus post-build checks for architecture, library leaks, and size. **[Full trust model →](docs/trust-model.md)**

If this trust model isn't right for you, build from source (next section) or use MacPorts (`sudo port install mkvtoolnix +qtgui`).

## Build from source

Requirements: Xcode CLI tools, ~10 GB disk space, 1–3 hours first build.

```sh
git clone https://github.com/CorticalCode/mkvtoolnix-gui-macos.git
cd mkvtoolnix-gui-macos
./build-local.sh --restore-cache    # optional, pulls pre-built deps from LFS
./build-local.sh release-100.0
```

The DMG will be at `~/tmp/compile/MKVToolNix-100.0.dmg`. See [docs/proven-cache.md](docs/proven-cache.md) for the cache architecture and `--full` for forced full rebuild.

## What this repo contains

- `build-local.sh` — clones upstream, applies patches, runs the build, verifies
- `config/config.local.sh` — config overlay (ad-hoc signing, optimization flags)
- `patches/` — fixes for the upstream build scripts ([details](PATCHES.md))
- `tools/` — pinned mbunkus public key and fingerprint for tarball + tag verification, plus `check-upstream-tag-signing.sh` for periodic validation that upstream is still GPG-signing release tags
- `.github/workflows/build.yml` — CI builds and publishes Apple Silicon DMGs
- `.github/workflows/verify-mbunkus-key.yml` — monthly cross-check of the pinned key against three independent sources

## Credits

All credit to [Moritz Bunkus](https://www.bunkus.org/blog/) and the MKVToolNix contributors for building and maintaining this incredible tool for over 20 years. Moritz provided macOS builds for many years despite not owning a Mac himself — thank you for that and for all the work that goes into MKVToolNix.

This repo builds on the work of the macOS build community on the [MKVToolNix forum](https://help.mkvtoolnix.download/):

- **[Miklos Juhasz](https://github.com/mjuhasz)** — contributed macOS patches upstream and documented key build fixes
- **Ryu67** — provided community ARM builds (v92 through v98.0)
- **umzyi99** — documented Qt version-specific fixes and dark mode icon support
- **SoCuul** — demonstrated signed and notarized builds on Apple Silicon
- **[Touchstone64](https://github.com/Touchstone64/package-mkvtoolnix-for-mac)** — now packages MKVToolNix's official **signed, notarized** macOS releases (Apple Silicon, Intel, universal) for the [official downloads page](https://mkvtoolnix.download/downloads.html#macosx) and the Homebrew `mkvtoolnix-app` cask; his macOS packaging work is upstream in MKVToolNix

The build patches in this repo were informed by solutions shared across the [Building MKVToolNix with GUI on a Mac](https://help.mkvtoolnix.download/t/building-mkvtoolnix-with-gui-on-a-mac/1361) and [Apple Silicon / Retirement of Rosetta 2](https://help.mkvtoolnix.download/t/apple-silicon-retirement-of-rosetta-2/1371) forum threads.

If you find MKVToolNix useful, consider supporting the project upstream.

Source: <https://codeberg.org/mbunkus/mkvtoolnix>
License: GPL v2
