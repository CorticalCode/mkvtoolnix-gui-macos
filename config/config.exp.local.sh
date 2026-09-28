# Wrapper config for experimental builds — sourced by tools/build-exp.sh in
# preference to config.local.sh.
#
# Production build-local.sh continues to use config.local.sh (which pins
# QTVER for alignment with specs-updates.patch). This file mirrors the
# wrapper's universal settings (signing, threads, optimization flags) but
# omits the QTVER pin so experimental builds defer to the source's specs.sh.

# Build locations — a root of its own, separate from the release tree, so an
# experiment can never install over what a release build depends on. Only the
# downloaded source tarballs are shared (MTX_SRC_ROOT): those are upstream
# archives verified before use, not build output.
#
#   /opt/mtx-exp/prefix   install prefix; the experimental cache lives beneath it
#   /opt/mtx-exp/build    compile workspace (upstream's CMPL)
#   /opt/mtx-exp/pkg      built package tarballs
#   /opt/mtx-exp/xsl      DocBook XSL stylesheets
#   /opt/mtx-exp/stage    DESTDIR staging root used by myinstall.sh
#   /opt/mtx/src          source tarballs, shared with the release tree
#
# Unconditional on purpose: config.sh is sourced first and exports its own
# $HOME-based values unconditionally, so a conditional form would lose to it.
export MTX_ROOT="${MTX_ROOT:-/opt/mtx-exp}"
export MTX_SRC_ROOT="${MTX_SRC_ROOT:-/opt/mtx}"

export TARGET="${MTX_ROOT}/prefix"
export CMPL="${MTX_ROOT}/build"
export SRCDIR="${MTX_SRC_ROOT}/src"
export PACKAGE_DIR="${MTX_ROOT}/pkg"
export DOCBOOK_XSL_ROOT_DIR="${MTX_ROOT}/xsl"
export STAGING_DIR="${MTX_ROOT}/stage"

# Ad-hoc code signing — required for macOS Sequoia 15.1+ which blocks
# completely unsigned apps. The "-" identity signs without a certificate.
# This doesn't notarize but allows Gatekeeper's "Open Anyway" flow to work.
export SIGNATURE_IDENTITY="-"

# Use more cores (default is 4)
export DRAKETHREADS=12

# Qt version: intentionally NOT pinned here. Experimental builds let upstream's
# config.sh default (`QTVER=${QTVER:-X.Y.Z}`) take effect, so build_qt
# operates on the version specified by the experimental source's specs.sh. This
# keeps experimental builds aligned with whatever Qt the source targets and
# avoids the build_qt directory mismatch (`cd qt-everywhere-src-${QTVER}`)
# that occurs when production's pinned version differs.

# Optimization flags — upstream sets no -O level in CFLAGS/CXXFLAGS,
# so autotools deps (Boost, FLAC, libogg, etc.) build at -O0 by default.
# -O2 is the standard release optimization. -dead_strip removes unreachable
# code at link time (complements the strip -x in build_dmg).
# The :- forms keep this file safe to source under `set -u`, where a bare
# ${CFLAGS} aborts when the variable is unset.
export CFLAGS="${CFLAGS:-} -O2"
export CXXFLAGS="${CXXFLAGS:-} -O2"
export LDFLAGS="${LDFLAGS:-} -Wl,-dead_strip"
