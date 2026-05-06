# Wrapper config for experimental builds — sourced by tools/build-exp.sh in
# preference to config.local.sh.
#
# Production build-local.sh continues to use config.local.sh (which pins
# QTVER for alignment with specs-updates.patch). This file mirrors the
# wrapper's universal settings (signing, threads, optimization flags) but
# omits the QTVER pin so experimental builds defer to the source's specs.sh.

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
export CFLAGS="${CFLAGS} -O2"
export CXXFLAGS="${CXXFLAGS} -O2"
export LDFLAGS="${LDFLAGS} -Wl,-dead_strip"
