# tools/

Helper scripts and trust artifacts for the wrapper build pipeline.

## Scripts

- **`build-exp.sh`** — experimental build entry point. Compiles a source tree you
  point it at (a worktree, a detached upstream snapshot) and owns the
  `~/opt/proven-experimental/` dep cache: it fills that cache after building
  missing deps and empties it with `--clear-cache`. Does not apply wrapper
  patches, and never writes to `release/`.
- **`refresh-deps.sh <tag>`** — rebuilds only the cached dependencies whose
  recorded source no longer matches a release tag, in upstream's build order,
  and repromotes just those. Run it when `build-local.sh` refuses a cache;
  `--dry-run` reports what would be rebuilt without building.
- **`check-upstream-tag-signing.sh`** — see "Periodically validating upstream
  tag-signing" below.
- **`backfill-sha256.sh`** — regenerates missing `.sha256` sidecars in the local
  caches and in `build/` / `release/`. Does not touch the repo's `proven/`.

## GPG verification of upstream artifacts

`build-local.sh` uses the pinned mbunkus key for two checks before running
the build:

1. **Tag signature** — `git verify-tag` on the upstream release tag (closes
   the gap where `specs.sh` and the dependency hashes inside it depended on
   Codeberg integrity alone).
2. **Tarball signature** — `gpg --verify` on
   `mkvtoolnix-${MTX_VER}.tar.xz` (catches both accidental local
   contamination — the 2026-04-20 incident — and a hypothetical
   `mkvtoolnix.download` server compromise).

Both checks use the same pinned key. See
[`docs/trust-model.md`](../docs/trust-model.md) for the full chain and
[`docs/tarball-verification.md`](../docs/tarball-verification.md) for
operational detail on the tarball-specific path.

### Files

- **`mbunkus-pubkey.asc`** — Moritz Bunkus's public key, fetched from
  the canonical source `https://bunkus.org/gpg-pub-moritzbunkus.txt`
  on 2026-04-25. Full key with all six user IDs and third-party
  signatures. 10057 bytes.

  Note: the keys.openpgp.org "minimal form" of this key has all UIDs
  stripped (because email confirmation hasn't been done by the key
  owner for that service). gpg refuses to verify against a UID-less
  key, so the bunkus.org form is required.

  Public keys are designed for redistribution; this is exactly the use
  case mbunkus published the key for.

- **`mbunkus-fingerprint.txt`** — Pinned 40-hex-char primary key
  fingerprint. The build script verifies the embedded `.asc`'s primary
  fingerprint matches this value before trusting it. Defends against
  silently swapping the `.asc` without also updating this file — the
  diff would show in two places, hard to miss in review.

### Provenance — fingerprint verified across four independent channels (2026-04-25)

| Source | Result |
|---|---|
| `https://bunkus.org/gpg-pub-moritzbunkus.txt` | `D9199745B0545F2E8197062B0F92290A445B9007` |
| `https://codeberg.org/mbunkus.gpg` | `D9199745B0545F2E8197062B0F92290A445B9007` |
| `https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xD919...` | `D9199745B0545F2E8197062B0F92290A445B9007` |
| `https://keys.openpgp.org/vks/v1/by-fingerprint/D919...` | `D9199745B0545F2E8197062B0F92290A445B9007` |

Signing subkey on the 98.0 release tarball: `3301A29D88D01A0CF999954F74AF00ADF2E32C85`
(rsa4096 [S], created 2015-02-10, child of the primary key above).

### Drift detection

`.github/workflows/verify-mbunkus-key.yml` re-runs the multi-source
fingerprint comparison monthly. Any mismatch (key rotation, revocation,
single-channel compromise) fails the workflow and emails the
maintainer. The workflow does not auto-update — drift requires a
human-reviewed PR.

### Refreshing the embedded key (manual)

If the workflow fails or the maintainer rotates a subkey:

1. Re-fetch from at least two independent sources, confirm primary
   fingerprint still matches `mbunkus-fingerprint.txt`
2. Replace `mbunkus-pubkey.asc` with the new fetch
3. Verify locally: `gpg --verify mkvtoolnix-${MTX_VER}.tar.xz.sig mkvtoolnix-${MTX_VER}.tar.xz`
4. Commit with provenance note in the message

If the primary fingerprint itself changes, that's a key rotation —
update `mbunkus-fingerprint.txt` too, but only after confirming the new
fingerprint via at least two out-of-band channels (e.g., a freshly
fetched `bunkus.org` page, signed announcement, in-person).

## Periodically validating upstream tag-signing

`tools/check-upstream-tag-signing.sh` clones upstream at recent release
tags and verifies each against the pinned key. Useful as a sanity check
that mbunkus is still signing tags consistently — for example after a
key-drift alert from `verify-mbunkus-key.yml`. Doesn't modify your repo
or trust artifacts; safe to run anytime.
