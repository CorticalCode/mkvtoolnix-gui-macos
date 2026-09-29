# Wrapper config for experimental builds — sourced by tools/build-exp.sh in
# preference to config.local.sh.
#
# Production build-local.sh continues to use config.local.sh (which pins
# QTVER for alignment with specs-updates.patch). This file mirrors the
# wrapper's universal settings (signing, threads, optimization flags) but
# omits the QTVER pin so experimental builds defer to the source's specs.sh.

# Build locations — a root of its own, separate from the release tree, so an
# experiment can never install over what a release build depends on.
# MTX_EXP_ROOT is the single knob; everything else derives from it:
#
#   /opt/mtx-exp/prefix   install prefix; the experimental cache, the built
#                         packages and the DocBook stylesheets all live beneath
#                         it, because the cache round-trip requires it
#   /opt/mtx-exp/build    compile workspace (upstream's CMPL)
#   /opt/mtx-exp/stage    DESTDIR staging root used by myinstall.sh
#   /opt/mtx-exp/src      source tarballs
#
# Experimental builds cannot borrow the release cache: every cached package
# records the prefix it was built under, so restoring release packages here
# would point the experiment at the release tree. The first experimental build
# compiles its own dependencies (--rebuild-deps).
export MTX_EXP_ROOT="${MTX_EXP_ROOT:-/opt/mtx-exp}"

# The root must be absolute, and must neither equal, lie inside nor hold the
# release root (/opt/mtx, or MTX_ROOT when set): this file is read from more
# than one working directory, and each track wipes its own prefix. Folders
# that exist are compared with symlinks resolved. Written for zsh and bash
# alike: tools/backfill-sha256.sh reads this file with bash.
_mtx_release_root="${MTX_ROOT:-/opt/mtx}"
_mtx_real() {
  local p="$1"
  if [ -d "${p}" ]; then
    p=$(cd -P -- "${p}" >/dev/null && pwd -P) || return 1
  fi
  while [ "${p%/}" != "${p}" ]; do p="${p%/}"; done
  printf '%s\n' "${p}"
}
_mtx_within() {
  case "$1/" in "$2/"*) return 0 ;; esac
  return 1
}
case "${MTX_EXP_ROOT}" in
  /*) ;;
  *)
    echo "ERROR: MTX_EXP_ROOT must be an absolute path, not '${MTX_EXP_ROOT}'." >&2
    exit 1 ;;
esac
if ! _mtx_exp=$(_mtx_real "${MTX_EXP_ROOT}") || ! _mtx_rel=$(_mtx_real "${_mtx_release_root}"); then
  echo "ERROR: cannot resolve MTX_EXP_ROOT (${MTX_EXP_ROOT}) or the release root (${_mtx_release_root})." >&2
  exit 1
fi
if _mtx_within "${_mtx_exp}" "${_mtx_rel}" || _mtx_within "${_mtx_rel}" "${_mtx_exp}"; then
  echo "ERROR: MTX_EXP_ROOT (${_mtx_exp}) overlaps the release root (${_mtx_rel})." >&2
  echo "       Each track wipes its own prefix, so one would destroy the other's." >&2
  echo "       Set MTX_EXP_ROOT or MTX_ROOT so that neither folder holds the other." >&2
  exit 1
fi
unset -f _mtx_real _mtx_within
unset _mtx_release_root _mtx_exp _mtx_rel

# Unconditional on purpose: config.sh is sourced first and exports its own
# $HOME-based values unconditionally, so a conditional form would lose to it.
export TARGET="${MTX_EXP_ROOT}/prefix"
export CMPL="${MTX_EXP_ROOT}/build"
export SRCDIR="${MTX_EXP_ROOT}/src"
export PACKAGE_DIR="${TARGET}/packages"
export DOCBOOK_XSL_ROOT_DIR="${TARGET}/xsl-stylesheets"
export STAGING_DIR="${MTX_EXP_ROOT}/stage"

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
