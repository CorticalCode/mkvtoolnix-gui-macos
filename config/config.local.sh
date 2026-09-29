# Wrapper config for production (release-track) builds. Sourced by
# build-local.sh and copied verbatim to packaging/macos/config.local.sh in
# the upstream tree — the filename matches upstream's expected name so the
# copy is one-to-one. Experimental sibling: config.exp.local.sh, which
# build-exp.sh stages AS config.local.sh at build time.

# Build locations — a fixed root in place of upstream's $HOME-based defaults
# in config.sh. MTX_ROOT is the single knob; everything else derives from it,
# so relocating the whole tree means setting one variable:
#
#   MTX_ROOT=/somewhere/else ./build-local.sh release-XX.0
#
# These assignments are unconditional on purpose. config.sh exports its own
# values unconditionally and is sourced first, so a conditional form here
# would always lose to it.
#
#   prefix/  install prefix; the proven cache, the built packages and the
#            DocBook stylesheets all live beneath it
#   build/   compile workspace (upstream's CMPL)
#   src/     downloaded source tarballs
#   stage/   DESTDIR staging root used by myinstall.sh
#
# PACKAGE_DIR and DOCBOOK_XSL_ROOT_DIR stay under TARGET because the cache
# round-trip depends on it: the docbook package is created relative to TARGET
# and restored by extracting into TARGET, so moving its source directory
# elsewhere breaks the restore. SRCDIR is outside TARGET on purpose — nothing
# is ever restored into it.
export MTX_ROOT="${MTX_ROOT:-/opt/mtx}"

export TARGET="${MTX_ROOT}/prefix"
export CMPL="${MTX_ROOT}/build"
export SRCDIR="${MTX_ROOT}/src"
export PACKAGE_DIR="${TARGET}/packages"
export DOCBOOK_XSL_ROOT_DIR="${TARGET}/xsl-stylesheets"
export STAGING_DIR="${MTX_ROOT}/stage"

# Ad-hoc code signing — required for macOS Sequoia 15.1+ which blocks
# completely unsigned apps. The "-" identity signs without a certificate.
# This doesn't notarize but allows Gatekeeper's "Open Anyway" flow to work.
export SIGNATURE_IDENTITY="-"

# Use more cores (default is 4)
export DRAKETHREADS=12

# Qt version is NOT pinned here — build-local.sh derives it automatically from
# the source's packaging/macos/specs.sh (the single source of truth), so a stale
# pin can no longer cause a wrong-Qt build and there's no manual bump per release.

# Optimization flags — upstream sets no -O level in CFLAGS/CXXFLAGS,
# so autotools deps (Boost, FLAC, libogg, etc.) build at -O0 by default.
# -O2 is the standard release optimization. -dead_strip removes unreachable
# code at link time (complements the strip -x in build_dmg).
# The :- forms keep this file safe to source under `set -u`, where a bare
# ${CFLAGS} aborts when the variable is unset.
export CFLAGS="${CFLAGS:-} -O2"
export CXXFLAGS="${CXXFLAGS:-} -O2"
export LDFLAGS="${LDFLAGS:-} -Wl,-dead_strip"
