# Trust model

This document describes what `mkvtoolnix-gui-macos` verifies, what it doesn't, and why. If you want the short version, the README's "Trust & install" section covers it. This is the long version for security-minded readers.

> **See also:** [tarball-verification.md](tarball-verification.md) for tarball-specific operational detail (sequence diagrams, refresh procedure, what to do if verification fails).

## TL;DR

- The DMGs are **ad-hoc signed**, not Apple-notarized. macOS blocks first launch; you override it once.
- Every build cryptographically verifies mbunkus's GPG signature on the upstream source **and** on the codeberg release tag, both against the same pinned key.
- Every dependency tarball is verified against an SHA256 hash pinned in upstream's `specs.sh`. The `specs.sh` file is itself trust-rooted in mbunkus's tag signature.
- The pinned mbunkus key is cross-checked monthly against three independent sources (bunkus.org, codeberg, keys.openpgp.org). Drift fails CI.
- DMGs built via the CI workflow include GitHub-issued build provenance attestations. Users can verify such a DMG was built by this exact workflow from a specific commit. DMGs built and uploaded manually (as the current v99 release was, both architectures) are not attested but inherit the same upstream verification.
- **What's not verified:** GPG signatures on individual dependency tarballs (Qt doesn't publish them, so coverage would be partial and misleading). Dependencies are SHA256-rooted instead.

## Why no notarization

Notarizing with my Apple Developer ID would tell macOS "this developer vouches for this binary." I don't, and won't.

I'm not the upstream maintainer. I'm a translator running someone else's source through a build script on my hardware. I haven't audited Qt 6.11.1's source — nobody could, realistically. I haven't reviewed boost 1.88. I'm in no position to back the chain of trust that Developer ID notarization implies. Mbunkus didn't notarize his official DMGs either, for the same structural reason: he didn't own a Mac and wasn't in a position to act as a vouching distributor.

This is also consistent with how MacPorts ships `mkvtoolnix +qtgui` today — same model, same trust posture. Notarization isn't part of the long-running pattern that brought users here.

If you need notarized macOS software, this isn't it, and that's a deliberate choice rather than an oversight or cost-cutting measure.

## The trust chain

Two independent paths land at the build:

1. **Tag signature** roots the build scripts and dependency hashes in mbunkus's key.
2. **Tarball signature** roots the mkvtoolnix source itself in the same key.

Both must succeed for a build to proceed. They cover different attack surfaces (codeberg vs. mkvtoolnix.download) with the same pinned key. The chain extends sideways into proven-cache integrity (§6) and forward into build-provenance attestation (§7) for CI builds.

For the tarball-specific path, [tarball-verification.md](tarball-verification.md) is the operational manual: sequence diagrams, drift-detection workflow, what to do if verification fails, key-refresh procedure.

## What's verified, by step

The relevant code is in `build-local.sh`. Specific blocks:

### 1. Pinned key integrity

The embedded `tools/mbunkus-pubkey.asc` is checked against the pinned fingerprint in `tools/mbunkus-fingerprint.txt` before either GPG check runs; mismatch aborts the build. See [tarball-verification.md § Trust artifacts](tarball-verification.md#trust-artifacts) for the artifact details, refresh procedure, and drift-detection workflow.

### 2. Codeberg tag signature

After cloning the upstream repo at the requested tag, `git verify-tag` is run with an isolated GPG keyring containing only the pinned mbunkus key. If the tag is unsigned, signed by a different key, or has an invalid signature, the build aborts.

This is the change that closes the gap where `specs.sh` integrity used to depend on codeberg integrity alone.

If you want to independently verify that mbunkus is still signing release tags consistently — for example, after a key rotation flagged by `verify-mbunkus-key.yml`, or just periodically as a sanity check — you can run:

```
./tools/check-upstream-tag-signing.sh
```

This clones upstream at a few recent release tags, verifies each against the pinned key, and reports the result. It's safe to run anytime; it doesn't modify your repo or trust artifacts.

### 3. Source tarball signature

`gpg --verify` runs against the pinned key on the upstream `mkvtoolnix-${VERSION}.tar.xz` and its detached `.sig`. Failure aborts the build with a remediation message. See [tarball-verification.md](tarball-verification.md) for the full operational deep-dive (download flow, sequence diagrams, what to do if verification fails).

As of 99.0, upstream's `build.sh` re-verifies the same tarball mid-build (`retrieve_verified_source_tarball`, using a `gnupg` it builds from source and a key it downloads live from `mkvtoolnix.download`). That's a weaker check — it trusts whatever key the server serves, with no pinned fingerprint — so this pinned-key step, which runs first, stays authoritative; upstream's is a redundant second pass.

### 4. Dependency SHA256

Upstream's `retrieve_file` function (from `packaging/macos/build.sh`) downloads each dependency over HTTPS and computes SHA256 against the hash in `specs.sh`. If the hash doesn't match, the build aborts. This is upstream behavior, but because step 2 cryptographically roots `specs.sh` in mbunkus's key, those hashes are now trusted.

### 5. Post-build verification

After the build produces a `.app` bundle, `build-local.sh` runs:

- Qt version match against `${QTVER}` from specs
- Architecture check on every binary and dylib (catches build-environment contamination)
- Duplicate dylib scan (catches package-cache corruption)
- Size sanity check (60–95 MB) against a known-good baseline
- Homebrew library leak detection via `otool -L` (catches `/opt/homebrew` or `/usr/local/opt` references that would crash on user machines)

These don't prove the binary is malware-free, but they do catch a wide range of build-environment issues that have actually happened in this repo's history (see PATCHES.md).

### 6. Proven cache integrity

When restoring pre-built dependencies from the proven cache (the `--restore-cache` workflow), each tarball is verified against a committed `.sha256` sidecar before extraction. The sidecars are generated and committed by `do_promote` and travel with the cache in Git LFS.

### 7. Build provenance (CI builds only)

CI-built DMGs ship with GitHub-issued build provenance attestations. End users can verify a downloaded DMG was built by this exact workflow from a specific commit:

```
gh attestation verify MKVToolNix-98.0-macos-apple-silicon.dmg --owner CorticalCode
```

This doesn't replace SHA256 verification; it complements it. SHA256 verifies the file is bit-identical to what was published. Attestation cryptographically proves which workflow run published it.

## What's not verified

### GPG signatures on dependency tarballs

This was considered and explicitly rejected. The reasoning:

- **Qt does not publish GPG signatures.** Qt is the largest dependency by far and the most security-relevant (renders user input, network code, etc.). Qt only publishes `md5sums.txt`, an unsigned hash file on the same server as the tarball.
- Per-dep verification would cover most dependencies (boost, gnu tools, xiph libs, cmark, cmake mostly publish signatures), but the most important one — Qt — does not.
- Partial coverage that excludes Qt would create a false sense of completeness while leaving the largest attack surface uncovered.

The `git verify-tag` approach gets equivalent protection for all dependencies simultaneously — `specs.sh` is signed by mbunkus, so the SHA256 hashes inside it inherit his attestation. This is the same model used by Debian, Homebrew, MacPorts, and most distribution package recipes: pinned hashes in a maintainer-signed recipe, no per-package GPG check.

### Audit of dependency source code

I have not read the source of Qt, boost, libogg, libvorbis, flac, zlib, gettext, cmark, gmp, autoconf, automake, pkg-config, libiconv, or cmake. Nobody has, in the strong sense — these are large projects with many contributors. Trust here roots in upstream maintainer reputation and the broader open-source review process, not in personal verification.

### Post-installation behavior

Once installed, the app does whatever MKVToolNix does. I don't run sandbox monitoring or behavioral analysis on the build output. Bugs or vulnerabilities in MKVToolNix itself or any of its dependencies will be present in this build to the same extent they're present in upstream.

## Threat model

This build chain is designed to resist:

- **Codeberg compromise** alone (caught by tag signature verification)
- **mkvtoolnix.download compromise** alone (caught by tarball signature verification)
- **Mirror compromise of dependency sites** (Qt's mirrors, boost's, etc.) — caught by SHA256 against `specs.sh`
- **In-transit modification** (HTTPS plus checksums)
- **Build environment contamination** (Homebrew leak detection)
- **Stale build artifacts** (workspace wipe before each build)
- **Local tampering with cached dependencies** (SHA256 sidecar verification on restore)

It is **not** designed to resist:

- Simultaneous compromise of both codeberg AND mbunkus's GPG key. Cross-source key drift detection (run monthly) would eventually catch a key rotation, but not within a single build cycle.
- Original poisoning — i.e., mbunkus being supplied a malicious tarball when he originally pinned the hash in specs.sh. Implausible but not provably prevented.
- Targeted attacks against me personally that compromise my build environment between source verification and binary signing.
- Vulnerabilities in MKVToolNix or its dependencies. This isn't a code audit.

## How to verify a downloaded DMG yourself

```
# 1. Bit-level integrity
shasum -a 256 -c MKVToolNix-98.0-macos-apple-silicon.dmg.sha256

# 2. Build provenance (Apple Silicon DMG only — built by CI workflow)
gh attestation verify MKVToolNix-98.0-macos-apple-silicon.dmg --owner CorticalCode

# 3. macOS code signature (ad-hoc, but valid)
codesign --verify --deep --strict --verbose=2 \
    /Volumes/MKVToolNix/MKVToolNix.app
spctl --assess --type execute --verbose \
    /Volumes/MKVToolNix/MKVToolNix.app
```

Step 2 (attestation) applies only to DMGs built via the CI workflow. The current v99 release was built and uploaded manually (both architectures), so it has no attestation; for it, steps 1 and 3 are the available checks.

Step 3 will return "rejected" because the DMG isn't notarized. That's expected. The verbose output will confirm the binary is ad-hoc signed and the signature is consistent (i.e., the app hasn't been modified since signing).

## Reproducing the build yourself

If you don't trust this repo's published binaries, the most direct alternative is to run the same build script yourself:

```
git clone https://github.com/CorticalCode/mkvtoolnix-gui-macos.git
cd mkvtoolnix-gui-macos
./build-local.sh release-98.0
```

This removes me from the trust chain. You're now trusting:

- mbunkus's GPG key (which `tools/mbunkus-fingerprint.txt` pins, and which you can independently verify against bunkus.org or keys.openpgp.org)
- Codeberg's git infrastructure
- Upstream MKVToolNix source code
- The 14 dependency upstreams
- Your own build environment

You're no longer trusting:

- Me
- GitHub Actions runners
- Anything in this repo beyond its public, reviewable code

This is the same trust posture as `sudo port install mkvtoolnix +qtgui` from MacPorts, with the added defense-in-depth of the GPG verification chain documented above.

## Updates and questions

If you find a problem with the trust chain — a verification step that's claimed but not actually running, an unverified link, or a documented step that doesn't match what the code does — please [open an issue](https://github.com/CorticalCode/mkvtoolnix-gui-macos/issues). Trust documentation that doesn't match the code is worse than no trust documentation.
