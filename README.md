# mkvtoolnix-gui-macos

Unofficial macOS builds of [MKVToolNix GUI](https://mkvtoolnix.download/) for Apple Silicon and Intel.

The MKVToolNix developer no longer provides macOS binaries as of v98.0. The CLI tools are available via `brew install mkvtoolnix`, but the GUI is not. This repo builds the full GUI from upstream source.

This repo is a personal learning project and proof-of-concept; the builds are shared as-is. No warranty, no SLA. Build scripts and patches are in this repo if you want to debug or build yourself.

## Download

| Date | Release | MKVToolNix | Apple Silicon | Intel |
|------|---------|:----------:|:-------------:|:-----:|
| 2026-05-24 | [v99.0-b2026.05.1](../../releases/tag/v99.0-b2026.05.1) | 99.0 | [DMG (27 MB)](../../releases/download/v99.0-b2026.05.1/MKVToolNix-99.0-macos-apple-silicon.dmg) | [DMG (30 MB)](../../releases/download/v99.0-b2026.05.1/MKVToolNix-99.0-macos-intel.dmg) |
| 2026-04-15 | [v98.0-b2026.04.3](../../releases/tag/v98.0-b2026.04.3) | 98.0 | [DMG (34 MB)](../../releases/download/v98.0-b2026.04.3/MKVToolNix-98.0-macos-apple-silicon.dmg) | [DMG (36 MB)](../../releases/download/v98.0-b2026.04.3/MKVToolNix-98.0-macos-intel.dmg) |

All releases on the [Releases page](../../releases).

Not sure which? Apple menu → About This Mac. "Apple M_" = Apple Silicon, "Intel Core" = Intel.

Each DMG ships with a matching `.sha256` file:

```
shasum -a 256 -c MKVToolNix-99.0-macos-apple-silicon.dmg.sha256
```

CI builds also include a build provenance attestation (verifiable with `gh attestation verify`).

## Trust & install

These DMGs are ad-hoc signed, not Apple-notarized. macOS will block the first launch — this is Gatekeeper working correctly. To override:

- **Either** right-click the app → Open, then confirm in the dialog (on macOS Sequoia and newer, may push you to System Settings → Privacy & Security → Open Anyway), **or**
- Run `xattr -cr /Applications/MKVToolNix*.app` to clear the quarantine attribute, then launch normally

This is the same trust model that applied to mbunkus's official DMGs before April 2026, and the same model MacPorts uses for its `+qtgui` variant. The DMG isn't notarized because notarizing would put my name on a chain of trust I can't honestly back — I'm not the upstream maintainer, I haven't audited Qt or boost or the other dependencies, and I'm in no position to vouch for them the way Developer ID signing implies.

What the build does verify: mbunkus's GPG signature on the MKVToolNix source tarball, his signed git tag on codeberg, SHA256 hashes on every dependency tarball, plus post-build checks for architecture, library leaks, and size. **[Full trust model →](docs/trust-model.md)**

If this trust model isn't right for you, build from source (next section) or use MacPorts (`sudo port install mkvtoolnix +qtgui`).

## Build from source

Requirements: Xcode CLI tools, ~10 GB disk space, 1–3 hours first build.

```sh
git clone https://github.com/CorticalCode/mkvtoolnix-gui-macos.git
cd mkvtoolnix-gui-macos
./build-local.sh --restore-cache    # optional, pulls pre-built deps from LFS
./build-local.sh release-99.0
```

The DMG will be at `~/tmp/compile/MKVToolNix-99.0.dmg`. See [docs/proven-cache.md](docs/proven-cache.md) for the cache architecture and `--full` for forced full rebuild.

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
- **Touchstone64** — tested v98.0 on macOS 26 and documented compatibility issues

The build patches in this repo were informed by solutions shared across the [Building MKVToolNix with GUI on a Mac](https://help.mkvtoolnix.download/t/building-mkvtoolnix-with-gui-on-a-mac/1361) and [Apple Silicon / Retirement of Rosetta 2](https://help.mkvtoolnix.download/t/apple-silicon-retirement-of-rosetta-2/1371) forum threads.

If you find MKVToolNix useful, consider supporting the project upstream.

Source: <https://codeberg.org/mbunkus/mkvtoolnix>
License: GPL v2
