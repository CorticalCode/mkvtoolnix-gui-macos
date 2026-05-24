# Wrapper config for production (release-track) builds. Sourced by
# build-local.sh and copied verbatim to packaging/macos/config.local.sh in
# the upstream tree — the filename matches upstream's expected name so the
# copy is one-to-one. Experimental sibling: config.exp.local.sh, which
# build-exp.sh stages AS config.local.sh at build time.

# Ad-hoc code signing — required for macOS Sequoia 15.1+ which blocks
# completely unsigned apps. The "-" identity signs without a certificate.
# This doesn't notarize but allows Gatekeeper's "Open Anyway" flow to work.
export SIGNATURE_IDENTITY="-"

# Use more cores (default is 4)
export DRAKETHREADS=12

# Qt version — MUST match spec_qt in upstream packaging/macos/specs.sh.
# Upstream tracks Qt directly now (no wrapper specs patch); bump this to match
# whenever upstream bumps Qt.
export QTVER=6.11.0

# Optimization flags — upstream sets no -O level in CFLAGS/CXXFLAGS,
# so autotools deps (Boost, FLAC, libogg, etc.) build at -O0 by default.
# -O2 is the standard release optimization. -dead_strip removes unreachable
# code at link time (complements the strip -x in build_dmg).
export CFLAGS="${CFLAGS} -O2"
export CXXFLAGS="${CXXFLAGS} -O2"
export LDFLAGS="${LDFLAGS} -Wl,-dead_strip"
