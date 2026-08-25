# Proven Dependency Cache

The build system caches compiled dependencies so that subsequent builds only need to rebuild MKVToolNix itself (~15 minutes instead of 1-3 hours).

## How it works

When you run `./build-local.sh release-XX.0`:

1. The workspace (`~/opt/`) is wiped clean (except the cache and source tarballs)
2. Compiled dependencies are restored from `~/opt/proven/{arch}/`. Each restored package is **SHA256-verified against its `.sha256` sidecar** before being trusted; a mismatch **or a missing sidecar** aborts the build (see [trust-model.md §6](trust-model.md) for context).
3. If all dependencies are found, only MKVToolNix is built from source
4. If any are missing, a full build from source runs automatically

The cache is per-architecture — Apple Silicon (arm64) and Intel (x86_64) have separate caches and cannot cross-contaminate.

## Populating the cache

### From Git LFS (recommended for most users)

The repository includes pre-built dependency caches via Git LFS. Thanks to `.lfsconfig`, cloning the repo does **not** download these large files — your clone stays small (~1 MB).

When you're ready to build, pull the cache for your architecture:

```sh
./build-local.sh --restore-cache
```

This downloads the proven dependencies for your architecture (~130 MB), copies them to `~/opt/proven/{arch}/`, and cleans up the repo working copy. Future builds will restore from this local cache automatically (~15 minutes instead of 1-3 hours).

If you prefer to build all dependencies from source instead, simply skip `--restore-cache` and run the build directly — it will detect the missing cache and do a full build.

### From a full build (if you need to build deps yourself)

After a successful `--full` build:

```sh
# Copy the built packages to your local proven cache
mkdir -p ~/opt/proven/arm    # or ~/opt/proven/intel
cp ~/opt/packages/*.tar.gz ~/opt/proven/arm/

# Write a .sha256 sidecar beside each one — a package without its hash is
# unverifiable, and the restore step refuses it
(cd ~/opt/proven/arm && for f in *.tar.gz; do shasum -a 256 "$f" > "$f.sha256"; done)
```

Future builds will restore from this cache automatically.

### The `--promote` flag (maintainers only)

The `--promote` flag is a maintainer operation that archives the proven cache to Git LFS and commits it to the repository. **Regular users should not use `--promote`** — it modifies the git history and would create conflicts when pulling upstream updates. Use the manual copy method above instead.

## What's in the cache

15 files per architecture — one `.tar.gz` per dependency:

| Package | Description |
|---------|-------------|
| autoconf, automake, pkg-config | Build tools |
| cmake | Build system (bootstrapped from source) |
| libiconv, gettext | Internationalization |
| libogg, libvorbis, flac | Audio codecs |
| zlib | Compression |
| cmark | CommonMark parser (used by GUI) |
| gmp | Arbitrary precision math |
| boost | C++ libraries |
| qt-everywhere-src | Qt 6 framework |
| docbook-xsl | Documentation stylesheets |

## Restoring from Git LFS

The proven cache is archived in the repository via Git LFS under `proven/{arch}/`. The repo's `.lfsconfig` prevents these files from being downloaded automatically on clone, keeping the repo lightweight.

On a new machine:

```sh
git clone https://github.com/CorticalCode/mkvtoolnix-gui-macos.git
cd mkvtoolnix-gui-macos

# Pull pre-built deps for your architecture and populate local cache
./build-local.sh --restore-cache

# Build (will restore from cache, ~15 minutes)
./build-local.sh release-XX.0
```

The `--restore-cache` flag handles everything: pulls LFS objects for your architecture only (~130 MB), copies them to `~/opt/proven/{arch}/`, and cleans up the repo working copy so it returns to its lightweight state.

## Forcing a full rebuild

To rebuild all dependencies from source (ignoring the cache):

```sh
./build-local.sh release-XX.0 --full
```

The proven cache is not modified by `--full` — it remains as a safety net.

## Invalidating a single dependency

If you modify a patch that affects a specific dependency without bumping its version, delete that package from the cache to force a rebuild:

```sh
rm ~/opt/proven/arm/qt-everywhere-src-6.11.1.tar.gz
./build-local.sh release-XX.0  # will detect missing Qt and do a full build
```
