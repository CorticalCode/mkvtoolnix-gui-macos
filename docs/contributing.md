# Working with this repo

This repo is a **personal learning project and proof-of-concept**. It exists
because the upstream MKVToolNix maintainer no longer ships macOS binaries and
I wanted GUI builds for my own use; sharing them is a side effect, not the
goal. Treat it accordingly.

## If you find a bug or have an idea

**Open an issue.** Constructive feedback is genuinely welcome — it's how I
learn what's broken or what could be better. Please pick one of the issue
templates so the relevant context (chip, macOS version, what failed) is
captured upfront.

There is **no commitment to accept any change** and **no SLA on response
time**. Sometimes within a day, sometimes weeks. That's the explicit
trade-off of using a personal/learning project rather than a maintained
product.

For MKVToolNix bugs that aren't specific to this macOS build (i.e. they
also reproduce on the official Windows or Linux builds), report them
upstream at <https://codeberg.org/mbunkus/mkvtoolnix/issues>. The
[MKVToolNix forum](https://help.mkvtoolnix.download/) is the right place
for general help and discussion.

## Pull requests

Pull requests are **not the primary contribution path** for this repo.
The repo isn't structured around external code review, and PRs may sit
unreviewed for extended periods.

If you've already prototyped a fix and want to share it: open an issue
describing the problem, the fix shape, and link to your branch or paste
the diff. That gives the change a chance to be discussed before either
of us invests in formal review.

## For people building from source themselves

If you've cloned this repo to build for yourself (rather than to
contribute), the things you need to know:

### Patches

- Patches live in `patches/` and apply against the upstream source
  cloned at the build's tagged release. See [`PATCHES.md`](../PATCHES.md)
  for what each patch does and why.
- Generate patches from `git diff` against the pristine upstream tree,
  not from the patched working state.
- Verify with `git apply --check patches/foo.patch` before committing.
- Document root cause in `PATCHES.md` for any new active patch.

### Build verification

Every build verifies upstream's release tag and source tarball against
the pinned mbunkus GPG key, plus SHA256-checks every dependency on cache
restore. See [`docs/trust-model.md`](trust-model.md) for the full picture
and [`docs/tarball-verification.md`](tarball-verification.md) for
tarball-specific operational detail.

### Commit messages

- `type: description` form (`fix`, `feat`, `perf`, `docs`, `chore`)
- Recent `git log` shows the convention
