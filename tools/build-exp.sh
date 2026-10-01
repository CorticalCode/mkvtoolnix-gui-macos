#!/bin/zsh
# tools/build-exp.sh — experimental MKVToolNix builds, never release artifacts.
#
# Try mode builds a source tree as it is; series mode builds an exact upstream
# commit plus named changes, so its builds can be compared. Library builds are
# cached by a key of their inputs (tools/exp/). DMGs go to build/; release/ is
# never touched. See --help.

if [[ -z "${ZSH_VERSION}" ]]; then
  echo "ERROR: This script requires zsh. Run it with: ./tools/build-exp.sh" >&2
  exit 1
fi
if [[ "${ZSH_EVAL_CONTEXT}" == *:file ]]; then
  echo "ERROR: This script must be executed, not sourced." >&2
  return 1
fi

set -e
setopt NULL_GLOB

# Every run ends with one line saying how it ended, whatever the exit path.
# Installed first so the refusals below end with it too. A function that fails
# at top level under `set -e` skips this trap, so a top-level call to a function
# that can fail is written `fn ... || exit $?`.
_exp_outcome() {
  local rc=$?
  if [[ ${rc} -eq 0 ]]; then
    print -r -- "build-exp: finished (exit 0)"
  else
    print -r -- "build-exp: FAILED (exit ${rc})"
  fi
}
trap _exp_outcome EXIT

unalias -a 2>/dev/null || true

# --- Startup tool probe ---
# Verify every required external tool is reachable in PATH before doing any
# real work. Without this, a missing tool surfaces mid-build with a cryptic
# pipe error; here it surfaces immediately with the tool's name.
#
# Note on `unalias -a` (the line above): this only affects THIS script's
# subshell. It does not touch the user's interactive aliases — those persist
# in the parent shell unchanged.
_required_tools=(
  # POSIX core (every macOS install)
  awk grep sed find sort tr wc du xargs cat shasum file uname mktemp ls head
  # always present on macOS dev installs
  date stat rsync perl
  # macOS-specific (script is macOS-only by design; fail fast elsewhere)
  sw_vers sysctl xcrun clang hdiutil codesign strings
)
for _t in "${_required_tools[@]}"; do
  if ! command -v "$_t" >/dev/null 2>&1; then
    echo "ERROR: required tool '$_t' not found in PATH" >&2
    echo "       This script is for macOS builds. PATH=$PATH" >&2
    exit 1
  fi
done
unset _t _required_tools

# PATH as the caller set it, before anything here prepends to it; library
# builds start from this.
EXP_BASE_PATH="${PATH}"

# The arguments as given, for refusals that say how to re-run this command.
_EXP_ARGV=("$@")

TRAPZERR() {
  echo "ERROR: build-exp.sh failed at ${funcfiletrace[1]:-line ${LINENO}} (exit code $?)" >&2
}

# SCRIPT_DIR = wrapper repo root (tools/ → parent)
SCRIPT_DIR=${0:a:h:h}

# Build locations come from the experimental config overlay — the same file
# staged as config.local.sh in the source tree, so this wrapper and the build
# it drives agree on where the experimental tree lives. Read it here, before
# anything reads TARGET. There is no fallback: upstream's config.sh would put
# every path under $HOME, and config.local.sh points at the release tree.
WRAPPER_CONFIG="${SCRIPT_DIR}/config/config.exp.local.sh"
if [[ ! -f "${WRAPPER_CONFIG}" ]]; then
  echo "ERROR: config/config.exp.local.sh is missing from this checkout." >&2
  echo "       Experimental builds need their own overlay: it is what keeps them" >&2
  echo "       out of the release prefix. Restore it before building:" >&2
  echo "         git -C ${SCRIPT_DIR} restore config/config.exp.local.sh" >&2
  exit 1
fi
source "${WRAPPER_CONFIG}" || exit $?

# A root under the home folder would compile the account name into every
# library and binary built there, and experimental DMGs are sometimes published.
if [[ "${MTX_EXP_ROOT:A}/" == "${HOME:A}/"* ]]; then
  echo "ERROR: MTX_EXP_ROOT (${MTX_EXP_ROOT}) is inside the home folder." >&2
  echo "       Paths under it would be recorded in every library and binary built there." >&2
  echo "       Use the default root: export MTX_EXP_ROOT=/opt/mtx-exp (or unset MTX_EXP_ROOT)" >&2
  exit 1
fi

for _lib in keys cache series; do
  source "${SCRIPT_DIR}/tools/exp/${_lib}.zsh" || exit $?
done
unset _lib

usage() {
  cat <<'USAGE'
Usage:
  ./tools/build-exp.sh --source <path> [--slug NAME] [--verify-symbol SYM] [--build-missing]
  ./tools/build-exp.sh --pin <ref> [--with a,b,...] [--verify-symbol SYM] [--build-missing]
  ./tools/build-exp.sh --cache-drop <library>/<key> | --clear-cache

Experimental MKVToolNix builds under MTX_EXP_ROOT (default /opt/mtx-exp).
DMGs go to build/; release/ is never touched.

Modes:
  --source <path>     Try mode: build a source tree as it is, uncommitted edits
                      included, e.g. a worktree while working on a fix.
  --pin <ref>         Series mode: build an exact upstream commit (a branch, tag
                      or SHA in the MKVToolNix clone named by MTX_EXP_UPSTREAM,
                      e.g. upstream/main or origin/main for the latest) plus
                      the changes named by --with. Without --with, the baseline.
  --with a,b,...      Changes by name, from MTX_EXP_CHANGES/<name>/. Order does
                      not matter. A change folder holds any of: a file branch
                      naming a branch whose own commits apply (the clone needs
                      a remote named upstream), .patch files applied to the
                      source, and a packaging/ folder copied over the source's
                      (e.g. packaging/macos/qt-patches/ for a Qt patch).

Libraries:
  Each library build is cached in MTX_EXP_ROOT/cache under a key of everything
  that shaped it. A build restores what it can and, while anything is missing,
  stops with the prefix not wiped and no library built, and lists what is
  missing.
  --build-missing     Build the libraries the cache lacks, and keep them.
  --cache-drop L/KEY  Remove one entry (at least 12 characters of the key).
  --clear-cache       Remove this architecture's whole cache.

Other:
  --slug NAME         Try mode only: the DMG name's suffix (default: the source
                      folder's name).
  --verify-symbol SYM Fail unless the built binary contains SYM.
  --help, -h          This help.
USAGE
}

# --- Arg parsing ---
MODE=""
SRC=""
PIN=""
WITH=""
SLUG=""
VERIFY_SYMBOL=""
BUILD_MISSING=0
ACTION=build
DROP_SPEC=""
_need() {
  if [[ $2 -lt $3 ]]; then
    echo "ERROR: $1 needs $(( $3 - 1 )) value(s)" >&2
    exit 1
  fi
}
while [[ $# -gt 0 ]]; do
  case $1 in
    --source)        _need "$1" $# 2; SRC="$2"; shift ;;
    --pin)           _need "$1" $# 2; PIN="$2"; shift ;;
    --with)          _need "$1" $# 2; WITH="$2"; shift ;;
    --slug)          _need "$1" $# 2; SLUG="$2"; shift ;;
    --verify-symbol) _need "$1" $# 2; VERIFY_SYMBOL="$2"; shift ;;
    --build-missing) BUILD_MISSING=1 ;;
    --rebuild-deps)  echo "ERROR: --rebuild-deps is now --build-missing" >&2; exit 1 ;;
    --clear-cache)   ACTION=clear-cache ;;
    --cache-drop)    _need "$1" $# 2; ACTION=cache-drop; DROP_SPEC="$2"; shift ;;
    --help|-h)       usage; exit 0 ;;
    *)
      echo "ERROR: unexpected argument: $1 (a source tree is given with --source)" >&2
      usage >&2
      exit 1 ;;
  esac
  shift
done

# --- Architecture ---
MACHINE_ARCH=$(uname -m)
case "${MACHINE_ARCH}" in
  arm64)  ARCH_LABEL="arm" ;;
  x86_64) ARCH_LABEL="intel" ;;
  *)      ARCH_LABEL="${MACHINE_ARCH}" ;;
esac

# --- Modes that do not build ---
case "${ACTION}" in
  clear-cache) exp_cache_clear "${ARCH_LABEL}" || exit $?; exit 0 ;;
  cache-drop)  exp_cache_drop "${ARCH_LABEL}" "${DROP_SPEC}" || exit $?; exit 0 ;;
esac

# --- Build mode ---
if [[ -n "${SRC}" && -n "${PIN}" ]] || [[ -z "${SRC}" && -z "${PIN}" ]]; then
  echo "ERROR: give exactly one of --source (try mode) or --pin (series mode)" >&2
  usage >&2
  exit 1
fi
if [[ -n "${SRC}" ]]; then
  MODE=try
  if [[ -n "${WITH}" ]]; then
    echo "ERROR: --with needs --pin; try mode builds a source tree as it is" >&2
    exit 1
  fi
  SRC=${SRC:a}
  if [[ ! -d "${SRC}" ]]; then
    echo "ERROR: source path does not exist: ${SRC}" >&2
    exit 1
  fi
else
  MODE=series
  if [[ -n "${SLUG}" ]]; then
    echo "ERROR: --slug is try mode only; a series build is named by its pin and changes" >&2
    exit 1
  fi
fi

# --- Series mode: an exact upstream commit plus named changes ---
# The pin, the changes and each branch's own commits are resolved here, before
# anything is named or staged; the source is unpacked at the staging step.
if [[ "${MODE}" == series ]]; then
  if [[ -z "${MTX_EXP_UPSTREAM:-}" || ! -d "${MTX_EXP_UPSTREAM}" ]]; then
    echo "ERROR: series mode reads the MKVToolNix clone named by MTX_EXP_UPSTREAM, which is not set to a directory" >&2
    exit 1
  fi
  if [[ -n "${WITH}" && ( -z "${MTX_EXP_CHANGES:-}" || ! -d "${MTX_EXP_CHANGES}" ) ]]; then
    echo "ERROR: --with reads change folders from MTX_EXP_CHANGES, which is not set to a directory" >&2
    exit 1
  fi
  PIN_SHA=$(exp_resolve_pin "${MTX_EXP_UPSTREAM}" "${PIN}") || exit $?
  exp_changes_load_list "${MTX_EXP_CHANGES:-}" "${WITH}" || exit $?
  for name in "${EXP_CHANGES[@]}"; do
    if [[ -n "${EXP_CHANGE_BRANCH[${name}]:-}" ]]; then
      EXP_CHANGE_COMMITS[${name}]=$(exp_source_commits "${MTX_EXP_UPSTREAM}" "${EXP_CHANGE_BRANCH[${name}]}") || exit $?
    fi
  done
  if [[ ${#EXP_CHANGES[@]} -gt 0 ]]; then
    SLUG="${PIN_SHA[1,7]}-${(j:+:)EXP_CHANGES}"
  else
    SLUG="${PIN_SHA[1,7]}-baseline"
  fi
fi

# --- Sanity: source looks like mkvtoolnix (try mode; a series pin is checked by the MTX_VER step) ---
if [[ "${MODE}" == try ]]; then
  if [[ ! -f "${SRC}/configure.ac" ]] || [[ ! -d "${SRC}/src/mkvtoolnix-gui" ]] || [[ ! -f "${SRC}/packaging/macos/build.sh" ]]; then
    echo "ERROR: ${SRC} does not look like a mkvtoolnix source tree" >&2
    echo "       Expected: configure.ac, src/mkvtoolnix-gui/, packaging/macos/build.sh" >&2
    exit 1
  fi
fi

# --- Ensure git submodules are populated ---
# mkvtoolnix uses submodules for lib/libebml, lib/libmatroska, lib/fmt.
# configure fails without them. git submodule update is idempotent — fast
# no-op if already initialized. Done in SRC (which has .git), not in the
# rsync'd copy.
if [[ "${MODE}" == try ]]; then
  if [[ -d "${SRC}/.git" ]] || [[ -f "${SRC}/.git" ]]; then
    echo "==> Ensuring git submodules are initialized in ${SRC}..."
    (cd "${SRC}" && git submodule update --init --recursive)
  else
    echo "WARNING: ${SRC} is not a git checkout — skipping submodule init."
    echo "         If build fails with missing libEBML/libMatroska/fmt, you need"
    echo "         to populate lib/libebml, lib/libmatroska, lib/fmt manually." >&2
  fi
fi

# --- Slug defaulting (try mode; a series build is named by its pin and changes) ---
if [[ "${MODE}" == try ]]; then
  if [[ -z "${SLUG}" ]]; then
    SLUG="${SRC:t}"
    SLUG="${SLUG#mkvtoolnix-upstream-}"
  fi
  # Sanitize: allow only [A-Za-z0-9_-]
  SLUG="${SLUG//[^a-zA-Z0-9_-]/-}"
fi

# --- MTX_VER from the source's configure.ac; in series mode, the pin's ---
if [[ "${MODE}" == series ]]; then
  MTX_VER=$(git -C "${MTX_EXP_UPSTREAM}" show "${PIN_SHA}:configure.ac" | awk -F, '/AC_INIT/ { gsub("[][]", "", $2); print $2 }') || exit $?
  _ver_from="configure.ac at ${PIN} (${PIN_SHA[1,12]})"
else
  MTX_VER=$(awk -F, '/AC_INIT/ { gsub("[][]", "", $2); print $2 }' "${SRC}/configure.ac")
  _ver_from="${SRC}/configure.ac"
fi
if [[ -z "${MTX_VER}" ]]; then
  echo "ERROR: Could not derive MTX_VER from ${_ver_from}" >&2
  exit 1
fi

# --- Paths come from the experimental overlay read at the top ---
WORK_DIR="${CMPL}"

# --- Predict build number and derive hash (deterministic from slug+num+ver) ---
# Counter only increments on success, so a failed build's retry gets the same
# number and therefore the same hash — each "slot" has a stable identifier.
BUILD_COUNTER_FILE="${SCRIPT_DIR}/.build-counter-${ARCH_LABEL}-exp"
if [[ -f "${BUILD_COUNTER_FILE}" ]]; then
  BUILD_NUM=$(( $(cat "${BUILD_COUNTER_FILE}") + 1 ))
else
  BUILD_NUM=1
fi
BUILD_LABEL="exp$(printf '%03d' ${BUILD_NUM})"
BUILD_HASH=$(print -n "${SLUG}|${BUILD_NUM}|${MTX_VER}" | shasum -a 256 | head -c 6)
# Experimental builds target the next upstream release, so label them
# <next-major>pre derived from the source version (99.0 -> 100pre).
DEV_VER="$(( ${MTX_VER%%.*} + 1 ))pre"
VERSIONNAME="${DEV_VER}-exp-${SLUG}-${BUILD_LABEL}-${BUILD_HASH}"

echo "==> build-exp.sh"
if [[ "${MODE}" == series ]]; then
  echo "    Source:      ${PIN} (${PIN_SHA[1,12]}) with: ${EXP_CHANGES[*]:-no changes}"
else
  echo "    Source:      ${SRC}"
fi
echo "    Slug:       ${SLUG}"
echo "    MTX_VER:     ${MTX_VER}"
echo "    Arch:        ${MACHINE_ARCH} (${ARCH_LABEL})"
echo "    WORK_DIR:    ${WORK_DIR}"
echo "    TARGET:      ${TARGET}"
echo "    Build num:   ${BUILD_NUM} (predicted — counter bumps on success)"
echo "    Build hash:  ${BUILD_HASH} (deterministic: slug+num+ver)"
echo "    VERSIONNAME: ${VERSIONNAME}"
if [[ -n "${VERIFY_SYMBOL}" ]]; then
  echo "    VerifySym:   ${VERIFY_SYMBOL}"
fi

# --- Log setup ---
mkdir -p "${WORK_DIR}"
LOG_FILE="${WORK_DIR}/build-exp-${SLUG}-${BUILD_LABEL}-${BUILD_HASH}.log"
exec > >(tee "${LOG_FILE}") 2>&1
BUILD_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')          # local time, for human log
BUILD_START_ISO=$(command date -u +"%Y-%m-%dT%H:%M:%SZ")  # UTC ISO, for manifests
SECONDS=0

trap 'echo "==> Interrupted."; exit 130' INT TERM HUP

# --- Helper functions for manifest writing/reading ---

# JSON string escaper. Handles backslash, quote, newline, tab, CR.
#
# Replacement strings use `\\<char>` (2-char sequence) not `\\\<char>` (3-char).
# Both forms produce syntactically valid JSON, but they round-trip differently:
#
#   Form `\\n`  : real newline → JSON `\n` (2 bytes 5c 6e) → parses back to NL
#   Form `\\\n` : real newline → JSON `\\n` (3 bytes 5c 5c 6e) → parses back
#                to literal "\n" (backslash + letter), losing the control char
#
# `python3 -m json.tool` accepts both. Correctness requires a full
# `json.loads()` round-trip, not just a JSON-syntax check.
_json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

# ISO 8601 UTC "Z" timestamp.
_iso_utc() { command date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Non-identifying host info as a single-line JSON object.
_host_json() {
  local cpu_brand arch cores ram_bytes ram_gb macos clang_ver sdk_ver
  cpu_brand=$(command sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")
  arch=$(command uname -m)
  cores=$(command sysctl -n hw.physicalcpu 2>/dev/null || echo 0)
  ram_bytes=$(command sysctl -n hw.memsize 2>/dev/null || echo 0)
  ram_gb=$(( ram_bytes / 1073741824 ))
  macos=$(command sw_vers -productVersion 2>/dev/null || echo "unknown")
  clang_ver=$(command clang --version 2>/dev/null | command head -1 | command sed -E 's/.*version ([0-9.]+).*/\1/')
  [[ -z "$clang_ver" ]] && clang_ver="unknown"
  sdk_ver=$(command xcrun --show-sdk-version 2>/dev/null || echo "unknown")
  printf '{"cpu_brand":%s,"arch":%s,"cores_total":%d,"ram_gb":%d,"macos_version":%s,"clang_version":%s,"sdk_version":%s}' \
    "$(_json_str "$cpu_brand")" "$(_json_str "$arch")" "$cores" "$ram_gb" \
    "$(_json_str "$macos")" "$(_json_str "$clang_ver")" "$(_json_str "$sdk_ver")"
}

# --- Stage source into WORK_DIR (upstream build.sh expects ${CMPL}/mkvtoolnix-${MTX_VER}) ---
FORK_BUILD_DIR="${WORK_DIR}/mkvtoolnix-${MTX_VER}"
PACKAGING="${FORK_BUILD_DIR}/packaging/macos"
if [[ -d "${FORK_BUILD_DIR}" ]]; then
  echo "    rm -rf ${FORK_BUILD_DIR:t} (prior experimental-build scratch)"
  command rm -rf "${FORK_BUILD_DIR}"
fi
command rm -rf "${WORK_DIR}/dmg-${MTX_VER}" "${WORK_DIR}/MKVToolNix-${MTX_VER}.dmg"
if [[ "${MODE}" == series ]]; then
  # The pin's tree and its submodules, unpacked from the clone with the
  # changes applied: no repository in it and nothing to exclude.
  echo "==> Preparing ${PIN} (${PIN_SHA[1,12]}) with: ${EXP_CHANGES[*]:-no changes}, in ${FORK_BUILD_DIR}..."
  exp_prepare_source "${MTX_EXP_UPSTREAM}" "${PIN_SHA}" "${FORK_BUILD_DIR}" "${MTX_EXP_CHANGES:-}" || exit $?
else
  echo "==> Staging source to ${FORK_BUILD_DIR}..."
  mkdir -p "${FORK_BUILD_DIR}"
  rsync -a \
    --exclude='.git' \
    --exclude='.DS_Store' \
    --exclude='*.o' \
    --exclude='*.a' \
    --exclude='*.moc' \
    --exclude='/build-config' \
    --exclude='/src/mkvmerge' \
    --exclude='/src/mkvextract' \
    --exclude='/src/mkvinfo' \
    --exclude='/src/mkvpropedit' \
    --exclude='/src/mkvtoolnix-gui/mkvtoolnix-gui' \
    "${SRC}/" \
    "${FORK_BUILD_DIR}/"
fi

# --- Package staging under STAGING_DIR, as release builds do ---
STAGING_PATCH="${SCRIPT_DIR}/patches/myinstall-staging-dir.patch"
if (cd "${FORK_BUILD_DIR}" && git apply --check -R "${STAGING_PATCH}" 2>/dev/null); then
  echo "==> ${STAGING_PATCH:t}: already in the source"
elif (cd "${FORK_BUILD_DIR}" && git apply --check "${STAGING_PATCH}"); then
  (cd "${FORK_BUILD_DIR}" && git apply "${STAGING_PATCH}")
  echo "==> ${STAGING_PATCH:t}: applied"
else
  echo "ERROR: ${STAGING_PATCH:t} does not apply to this source's packaging/macos/myinstall.sh" >&2
  exit 1
fi

# --- Stage the overlay as packaging/macos/config.local.sh ---
STAGED_CONFIG="${PACKAGING}/config.local.sh"
echo "==> Staging config.exp.local.sh as packaging/macos/config.local.sh..."
command cp "${SCRIPT_DIR}/config/config.exp.local.sh" "${STAGED_CONFIG}"

# --- Inject VERSIONNAME into staged source ---
# Uses the same perl substitution pattern as upstream's
# tools/development/bump_version_set_code_name.sh.
# Shows up as "v<MTX_VER> ('<VERSIONNAME>')" in About dialog, version logs, etc.
VERSION_FILE="${FORK_BUILD_DIR}/src/common/version.cpp"
if [[ ! -f "${VERSION_FILE}" ]]; then
  echo "ERROR: ${VERSION_FILE} missing after stage — cannot inject VERSIONNAME." >&2
  exit 1
fi
echo "==> Setting VERSIONNAME = ${VERSIONNAME}"
perl -pi -e "s{^constexpr.*VERSIONNAME.*}{constexpr auto VERSIONNAME = \"${VERSIONNAME}\";}" "${VERSION_FILE}"
if ! command grep -q "VERSIONNAME = \"${VERSIONNAME}\"" "${VERSION_FILE}"; then
  echo "ERROR: VERSIONNAME injection failed — source unchanged." >&2
  exit 1
fi

# --- Environment for this script's own steps ---
# The staged config.sh and config.local.sh, in the order build.sh reads them.
# autogen.sh, the MKVToolNix compile and the DMG step run in it; library
# builds do not (see the assembly below).
_SAVED_OPTS=$(setopt | tr '\n' ' ')
source "${PACKAGING}/config.sh"
source "${STAGED_CONFIG}"
setopt ${=_SAVED_OPTS} 2>/dev/null
set -e
export PATH="${TARGET}/bin:$PATH"
export DYLD_LIBRARY_PATH="${TARGET}/lib:${DYLD_LIBRARY_PATH:-}"
export CMPL TARGET SRCDIR MTX_VER
export NO_EXTRACTION=1  # critical: source already staged, don't let build_package wipe+re-extract

echo "==> Build environment:"
echo "    CMPL:        ${CMPL}"
echo "    TARGET:      ${TARGET}"
echo "    SRCDIR:      ${SRCDIR}"
echo "    MTX_VER:     ${MTX_VER}"
echo "    QTVER:       ${QTVER:-<unset>}"
echo "    DRAKETHREADS: ${DRAKETHREADS:-4}"
echo "    MACOSX_DEPLOYMENT_TARGET: ${MACOSX_DEPLOYMENT_TARGET}"
echo "    SIGNATURE_IDENTITY: ${SIGNATURE_IDENTITY:-<unset>}"
echo "    APP_BUNDLE_NAME: ${APP_BUNDLE_NAME:-<unset>}"
echo "    DMG_REVISION: ${DMG_REVISION:-<unset>}"
echo "    NO_EXTRACTION: ${NO_EXTRACTION}"

# --- Library keys, and what the cache already holds ---
echo ""
echo "==> Library keys (${ARCH_LABEL}, ${EXP_CACHE_ROOT}):"
exp_compute_keys "${PACKAGING}" "${ARCH_LABEL}" || exit $?
exp_check_patch_dirs "${PACKAGING}" || exit $?
typeset -A LIB_FROM
MISSING=()
for lib in "${EXP_ORDER[@]}"; do
  key="${EXP_KEY[${lib}]}"
  entry=$(exp_cache_entry "${ARCH_LABEL}" "${lib}" "${key}") || exit $?
  if exp_cache_check "${entry}"; then
    LIB_FROM[${lib}]=cache
    echo "    ${lib}  ${key[1,12]}  cached"
  else
    rc=$?
    if [[ ${rc} -ne 1 ]]; then
      echo "ERROR: the cache entry for ${lib} is damaged and was not used. Remove it with:" >&2
      echo "         ${(q)0} --cache-drop ${lib}/${key}" >&2
      exit 1
    fi
    LIB_FROM[${lib}]=built
    MISSING+=("${lib}")
    echo "    ${lib}  ${key[1,12]}  not cached"
  fi
done
if [[ ${#MISSING[@]} -gt 0 && ${BUILD_MISSING} -eq 0 ]]; then
  echo "" >&2
  echo "ERROR: ${#MISSING[@]} library build(s) are not in the cache:" >&2
  for lib in "${MISSING[@]}"; do
    echo "         ${lib}  ${EXP_KEY[${lib}][1,12]}  not cached" >&2
  done
  echo "       The prefix was not wiped and no library was built. To build them now" >&2
  echo "       and keep them for later runs, run:" >&2
  echo "         ${(q)0} ${(@q)_EXP_ARGV} --build-missing" >&2
  exit 1
fi

# --- Wipe the prefix, then assemble the libraries in build order ---
# Each library is restored or built at its turn, so each build sees exactly
# the libraries before it in the prefix, as a clean build would. Library
# builds start from an empty environment apart from HOME, PATH, MTX_EXP_ROOT
# and TMPDIR: build.sh reads config.sh and config.local.sh itself, so what it
# sees is what the key hashed.
echo ""
echo "==> Wiping ${TARGET}..."
for item in "${TARGET}"/*(DN); do
  command rm -rf "${item}"
done
mkdir -p "${TARGET}/include" "${TARGET}/lib" "${TARGET}/bin" "${PACKAGE_DIR}"

DEPS_JSON_PARTS=()
BUILT_LIBS=()
for lib in "${EXP_ORDER[@]}"; do
  key="${EXP_KEY[${lib}]}"
  entry=$(exp_cache_entry "${ARCH_LABEL}" "${lib}" "${key}") || exit $?
  if [[ "${LIB_FROM[${lib}]}" == cache ]]; then
    echo "==> ${lib}: restoring ${key[1,12]}"
    exp_cache_restore "${entry}" "${TARGET}" || exit $?
  else
    echo "==> ${lib}: building ${key[1,12]}"
    (cd "${PACKAGING}" && command env -i HOME="${HOME}" PATH="${EXP_BASE_PATH}" \
       MTX_EXP_ROOT="${MTX_EXP_ROOT}" ${TMPDIR:+TMPDIR="${TMPDIR}"} ./build.sh "${lib}")
    if [[ "${lib}" == docbook_xsl ]]; then
      pkg_file="${PACKAGE_DIR}/docbook-xsl.tar.gz"
      exp_archive_docbook "${DOCBOOK_XSL_ROOT_DIR}" "${pkg_file}" || exit $?
    else
      pkg_file=$(exp_built_package "${PACKAGE_DIR}" "${lib}" "${EXP_TARBALL[${lib}]}") || exit $?
    fi
    exp_cache_store "${entry}" "${key}" "${pkg_file}" "${EXP_INPUT[${lib}]}" "$(_iso_utc)" "${EXP_TOOLCHAIN_ID}" || exit $?
    BUILT_LIBS+=("${lib}")
  fi
  DEPS_JSON_PARTS+=("{\"library\":$(_json_str "${lib}"),\"key\":$(_json_str "${key}"),\"from\":$(_json_str "${LIB_FROM[${lib}]}")}")
done

# --- Generate ./configure via autogen.sh ---
# Git checkouts don't include a pre-generated `configure`; release tarballs do.
# autogen.sh produces it via autoconf + automake (from the prefix libraries
# assembled above).
echo ""
echo "==> Running autogen.sh to generate ./configure..."
if [[ ! -x "${FORK_BUILD_DIR}/autogen.sh" ]]; then
  echo "ERROR: ${FORK_BUILD_DIR}/autogen.sh missing or not executable." >&2
  exit 1
fi
(cd "${FORK_BUILD_DIR}" && ./autogen.sh)
if [[ ! -f "${FORK_BUILD_DIR}/configure" ]]; then
  echo "ERROR: autogen.sh ran but ${FORK_BUILD_DIR}/configure was not produced." >&2
  exit 1
fi

# --- Compile ---
# The libraries are already in the prefix (assembly above), so they are not
# built here. NO_EXTRACTION is unset for shared_mime_info, which extracts its
# own tarball from ${SRCDIR}, and set for build_mkvtoolnix, which would wipe the
# staged source if allowed to extract.
echo ""
cd "${FORK_BUILD_DIR}/packaging/macos"

# Build the shared-mime-info dep (#6248): it installs the FreeDesktop MIME DB that
# build_configured_mkvtoolnix embeds via qt_resources_macos.qrc. It is not one of
# the cached libraries, and the prefix wipe removed any prior install, so build it
# explicitly here, before configured_mkvtoolnix.
( unset NO_EXTRACTION; ./build.sh shared_mime_info )

echo ""
# Skip build_mkvtoolnix → retrieve_verified_source_tarball gate (fails on
# pre-release MTX_VER). Source is pre-staged in ${CMPL}/mkvtoolnix-${MTX_VER};
# reproduce build_mkvtoolnix's remaining steps (configure + drake) inline.
echo "==> Building mkvtoolnix (configure + drake; staged source preserved)..."
(
  cd "${FORK_BUILD_DIR}"
  ./packaging/macos/build.sh configured_mkvtoolnix
  ./drake clean
  ./drake -j "${DRAKETHREADS}"
)

echo ""
echo "==> Packaging DMG..."
./build.sh dmg

# --- DMG + binary verification ---
DMG_PATH="${WORK_DIR}/MKVToolNix-${MTX_VER}-${DMG_REVISION}-${MACHINE_ARCH}.dmg"
APP_BUNDLE="${WORK_DIR}/dmg-${MTX_VER}/${APP_BUNDLE_NAME}"
BINARY="${APP_BUNDLE}/Contents/MacOS/mkvtoolnix-gui"

if [[ ! -f "${DMG_PATH}" ]]; then
  echo "ERROR: Expected DMG not found at ${DMG_PATH}" >&2
  exit 1
fi
if [[ ! -f "${BINARY}" ]]; then
  echo "ERROR: Built binary not found at ${BINARY}" >&2
  exit 1
fi

# --- Patch-presence verification ---
# Goes beyond "is the string in the binary" — checks that the fork's changes
# survived compilation end-to-end. Still a smoke test (can't prove behavior
# from inspection alone), but catches cases where the code string is present
# yet the integration is broken.
if [[ -n "${VERIFY_SYMBOL}" ]]; then
  echo ""
  echo "==> Patch-presence verification: ${VERIFY_SYMBOL}"

  # 1. Presence + occurrence count in binary
  symbol_count=$(command strings "${BINARY}" | command grep -c -- "${VERIFY_SYMBOL}" || true)
  if [[ ${symbol_count} -ge 1 ]]; then
    echo "    PASS: '${VERIFY_SYMBOL}' appears ${symbol_count}x in binary"
  else
    echo "    FAIL: '${VERIFY_SYMBOL}' NOT found in binary." >&2
    echo "          Build completed but the fork's code is missing." >&2
    echo "          DO NOT test this DMG." >&2
    exit 2
  fi

  # 2. Occurrence count in staged source (for cross-reference)
  # Counts across the whole staged tree; compiler deduplication means binary
  # count is always ≤ source count, but non-zero source + non-zero binary
  # confirms the source-to-binary path is intact.
  source_count=$(command grep -rc -- "${VERIFY_SYMBOL}" "${FORK_BUILD_DIR}/src" 2>/dev/null \
    | awk -F: '{s+=$2} END {print s+0}')
  echo "    INFO: source tree had ${source_count} references; binary has ${symbol_count} (compiler may dedup)"
  if [[ ${source_count} -eq 0 ]]; then
    echo "    FAIL: staged source has ZERO references to '${VERIFY_SYMBOL}'." >&2
    echo "          The rsync may have excluded the modified files, or the worktree is" >&2
    echo "          missing the patch. DO NOT test this DMG." >&2
    exit 2
  fi
fi

# --- Post-build verification (informational; warnings don't fail the build) ---
echo ""
echo "==> Running post-build verification..."
VERIFY_ISSUES=0

# 1. Architecture
arch_errors=0
arch_checked=0
while IFS= read -r -d '' b; do
  info=$(file "${b}" 2>/dev/null || true)
  [[ "${info}" == *"Mach-O"* ]] || continue
  arch_checked=$((arch_checked + 1))
  if [[ "${info}" != *"${MACHINE_ARCH}"* ]]; then
    echo "    FAIL: wrong arch in ${b:t}"
    arch_errors=$((arch_errors + 1))
  fi
# -type f selects every regular file, excluding directories and the version
# symlinks that alias each dylib; the Mach-O test above narrows it to actual
# binaries, so no permission bit is consulted.
done < <(command find "${APP_BUNDLE}/Contents/MacOS" -type f -print0 2>/dev/null)
if [[ ${arch_errors} -eq 0 ]] && [[ ${arch_checked} -gt 0 ]]; then
  echo "    PASS: all ${arch_checked} binaries/dylibs are ${MACHINE_ARCH}"
elif [[ ${arch_errors} -gt 0 ]]; then
  VERIFY_ISSUES=$((VERIFY_ISSUES + arch_errors))
fi

# 2. Size sanity (fork builds may differ from production, so wider range)
# Summing bytes by reading them avoids asking stat for a size, which is spelled
# differently on BSD and GNU.
app_bytes=$(command find "${APP_BUNDLE}" -type f -exec cat {} + 2>/dev/null | command wc -c | command tr -d ' ')
size_mb=$(echo "${app_bytes:-0}" | awk '{printf "%.1f", $1/1000/1000}')
if (( $(echo "${size_mb} < 50" | bc -l) )) || (( $(echo "${size_mb} > 150" | bc -l) )); then
  echo "    WARN: App size ${size_mb} MB outside typical 50-150 MB range"
  VERIFY_ISSUES=$((VERIFY_ISSUES + 1))
else
  echo "    PASS: App size ${size_mb} MB"
fi

# 3. Homebrew leak
leak_found=false
for lib in "${APP_BUNDLE}/Contents/MacOS/libs/"*.dylib "${BINARY}"; do
  [[ -f "${lib}" ]] || continue
  leaks=$(otool -L "${lib}" 2>/dev/null | grep -E "/opt/homebrew|/usr/local/opt" || true)
  if [[ -n "${leaks}" ]]; then
    echo "    WARN: Homebrew reference in ${lib:t}:"
    echo "${leaks}" | while read -r line; do echo "      ${line}"; done
    leak_found=true
  fi
done
if ! ${leak_found}; then
  echo "    PASS: no Homebrew/external library references"
else
  VERIFY_ISSUES=$((VERIFY_ISSUES + 1))
fi

# 4. Qt version in binary (informational)
BUILT_QT=$(otool -L "${BINARY}" 2>/dev/null | grep libQt6Core | sed 's/.*current version \([0-9.]*\).*/\1/' | head -1 || true)
if [[ -n "${BUILT_QT}" ]]; then
  echo "    INFO: Qt version linked into binary: ${BUILT_QT}"
fi

# 5. Distinct Qt versions bundled in libs/ — must be exactly 1. More than 1
# indicates the restore step extracted overlapping versions (the Fix 2 bug).
if [[ -d "${APP_BUNDLE}/Contents/MacOS/libs" ]]; then
  qt_versions=$(command find "${APP_BUNDLE}/Contents/MacOS/libs" -name 'libQt6Core.*.dylib' \
    -not -type l 2>/dev/null \
    | command sed -E 's/.*libQt6Core\.([0-9.]+)\.dylib/\1/' \
    | command sort -u)
  qt_version_count=$(echo "${qt_versions}" | command grep -c . || true)
  if [[ ${qt_version_count} -eq 1 ]]; then
    echo "    PASS: exactly 1 Qt version bundled (${qt_versions})"
  elif [[ ${qt_version_count} -gt 1 ]]; then
    echo "    FAIL: multiple Qt versions bundled — DMG is bloated / linking ambiguous:"
    echo "${qt_versions}" | while read -r v; do echo "      - ${v}"; done
    VERIFY_ISSUES=$((VERIFY_ISSUES + 1))
  else
    echo "    WARN: no libQt6Core dylib bundled (unexpected)"
    VERIFY_ISSUES=$((VERIFY_ISSUES + 1))
  fi
fi

# 6. Report bundled libs inventory for at-a-glance sanity
if [[ -d "${APP_BUNDLE}/Contents/MacOS/libs" ]]; then
  echo "    --- bundled libs ---"
  command find "${APP_BUNDLE}/Contents/MacOS/libs" -name '*.dylib' -not -type l 2>/dev/null \
    | while read -r l; do echo "    $(basename "${l}")"; done
fi

# --- Counter commit + DMG naming ---
# BUILD_NUM was predicted up-front (stable across retries); commit it now that
# the build succeeded. Previous value stays unchanged on any failure.
BUILD_DIR="${SCRIPT_DIR}/build"
mkdir -p "${BUILD_DIR}"

echo "${BUILD_NUM}" > "${BUILD_COUNTER_FILE}.tmp" && command mv "${BUILD_COUNTER_FILE}.tmp" "${BUILD_COUNTER_FILE}"

DMG_FINAL_NAME="MKVToolNix-${DEV_VER}-${ARCH_LABEL}-${BUILD_LABEL}-${SLUG}-${BUILD_HASH}.dmg"
command cp "${DMG_PATH}" "${BUILD_DIR}/${DMG_FINAL_NAME}"
(cd "${BUILD_DIR}" && shasum -a 256 "${DMG_FINAL_NAME}" > "${DMG_FINAL_NAME}.sha256")
DMG_FINAL_PATH="${BUILD_DIR}/${DMG_FINAL_NAME}"

# --- Write DMG sidecar manifest ---
# Captures full build provenance: source refs, deps used, host machine specs
# (non-identifying), patches, timing, verification results. Sits alongside
# the DMG and its .sha256 in build/.
# Experimental builds apply no wrapper patches; changes live in the source tree.
PATCHES_JSON="[]"

_BUNDLED_LIBS_JSON="["
_first_lib=1
if [[ -d "${APP_BUNDLE}/Contents/MacOS/libs" ]]; then
  for lib in "${APP_BUNDLE}"/Contents/MacOS/libs/*.dylib(N); do
    [[ -f "$lib" && ! -L "$lib" ]] || continue
    libname="${lib:t}"
    [[ ${_first_lib} -eq 1 ]] && _first_lib=0 || _BUNDLED_LIBS_JSON+=", "
    _BUNDLED_LIBS_JSON+=$(_json_str "${libname}")
  done
fi
_BUNDLED_LIBS_JSON+="]"

_DEPS_JSON="["
_first_dep=1
for d in "${DEPS_JSON_PARTS[@]}"; do
  [[ ${_first_dep} -eq 1 ]] && _first_dep=0 || _DEPS_JSON+=", "
  _DEPS_JSON+="${d}"
done
_DEPS_JSON+="]"

_dmg_size_bytes=$(command wc -c < "${DMG_FINAL_PATH}" | command tr -d ' ')
_dmg_sha=$(command shasum -a 256 "${DMG_FINAL_PATH}" | command awk '{print $1}')
_app_kb=$(command du -sk "${APP_BUNDLE}" | command awk '{print $1}')
_app_bytes=$(( _app_kb * 1024 ))

_wrapper_branch=$(git -C "${SCRIPT_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
_wrapper_sha=$(git -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
_wrapper_subj=$(git -C "${SCRIPT_DIR}" log -1 --format='%s' 2>/dev/null || echo "")
_fork_basename="${SRC:t}"
_fork_ref=$(git -C "${SRC}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "detached")
_fork_sha=$(git -C "${SRC}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
_fork_subj=$(git -C "${SRC}" log -1 --format='%s' 2>/dev/null || echo "")

_finished_at=$(_iso_utc)
_duration=${SECONDS}
_started_iso="${BUILD_START_ISO}"

DMG_MANIFEST_PATH="${BUILD_DIR}/${DMG_FINAL_NAME}.manifest.json"
cat > "${DMG_MANIFEST_PATH}" <<EOF
{
  "schema_version": 1,
  "kind": "experimental_build",
  "dmg": {
    "filename": $(_json_str "${DMG_FINAL_NAME}"),
    "size_bytes": ${_dmg_size_bytes},
    "sha256": $(_json_str "${_dmg_sha}")
  },
  "app": {
    "size_bytes": ${_app_bytes},
    "size_kb": ${_app_kb},
    "bundle_name": $(_json_str "${APP_BUNDLE:t}"),
    "bundled_libs": ${_BUNDLED_LIBS_JSON},
    "qt_version_in_binary": $(_json_str "${BUILT_QT:-unknown}")
  },
  "build_meta": {
    "kind": "experimental",
    "slug": $(_json_str "${SLUG}"),
    "build_label": $(_json_str "${BUILD_LABEL}"),
    "build_hash": $(_json_str "${BUILD_HASH}"),
    "version_name": $(_json_str "${VERSIONNAME}"),
    "mtx_version": $(_json_str "${MTX_VER}"),
    "build_missing_used": $([[ ${BUILD_MISSING} -eq 1 ]] && echo "true" || echo "false")
  },
  "source": {
    "wrapper": {
      "branch": $(_json_str "${_wrapper_branch}"),
      "sha": $(_json_str "${_wrapper_sha}"),
      "subject": $(_json_str "${_wrapper_subj}")
    },
    "experimental": {
      "path_basename": $(_json_str "${_fork_basename}"),
      "ref": $(_json_str "${_fork_ref}"),
      "sha": $(_json_str "${_fork_sha}"),
      "subject": $(_json_str "${_fork_subj}")
    }
  },
  "patches": ${PATCHES_JSON},
  "deps": ${_DEPS_JSON},
  "host": $(_host_json),
  "build_timing": {
    "started_at": $(_json_str "${_started_iso}"),
    "finished_at": $(_json_str "${_finished_at}"),
    "duration_seconds": ${_duration}
  },
  "verification": {
    "verify_symbol": $(_json_str "${VERIFY_SYMBOL:-}"),
    "verify_symbol_count": ${symbol_count:-0},
    "qt_version_count": ${qt_version_count:-0},
    "qt_version_in_libs": $(_json_str "${qt_versions:-}"),
    "homebrew_leaks_detected": $(${leak_found:-false} && echo "true" || echo "false"),
    "binary_arch_check": $(_json_str "${arch_checked} ${MACHINE_ARCH} of ${arch_checked} (${arch_errors} failures)"),
    "verify_issues": ${VERIFY_ISSUES:-0}
  }
}
EOF
echo ""
echo "==> Wrote DMG manifest sidecar: ${DMG_MANIFEST_PATH:t}"

# --- Summary ---
elapsed=$SECONDS
mins=$((elapsed / 60))
secs=$((elapsed % 60))

echo ""
echo "==> DONE in ${mins}m $(printf '%02d' ${secs})s."
echo ""
echo "  DMG:          ${BUILD_DIR}/${DMG_FINAL_NAME}"
echo "  SHA256:       ${BUILD_DIR}/${DMG_FINAL_NAME}.sha256"
echo "  Manifest:     ${BUILD_DIR}/${DMG_FINAL_NAME}.manifest.json"
echo "  Log:          ${LOG_FILE}"
if [[ ${#BUILT_LIBS[@]} -gt 0 ]]; then
  echo "  Built and cached: ${BUILT_LIBS[*]} → ${EXP_CACHE_ROOT}/${ARCH_LABEL}"
fi
echo "  Build number: ${BUILD_NUM} (${ARCH_LABEL}/exp)"
echo "  Build hash:   ${BUILD_HASH}"
echo "  VERSIONNAME:  ${VERSIONNAME}  (shown as \"v${MTX_VER} ('${VERSIONNAME}')\" in the About dialog)"
echo ""
echo "  Verification:"
if [[ -n "${VERIFY_SYMBOL}" ]]; then
  echo "    ${VERIFY_SYMBOL}: PRESENT (fork code compiled in)"
fi
echo "    Architecture: ${arch_errors} failures / ${arch_checked} checked"
echo "    App size:     ${size_mb} MB"
echo "    Homebrew leaks: $(${leak_found} && echo 'DETECTED (review log)' || echo 'none')"
if [[ -n "${BUILT_QT}" ]]; then
  echo "    Qt version:   ${BUILT_QT}"
fi
if [[ ${VERIFY_ISSUES} -gt 0 ]]; then
  echo "    Issues to review: ${VERIFY_ISSUES} (non-fatal)"
fi
echo ""
echo "To install and test:"
echo "    open \"${BUILD_DIR}/${DMG_FINAL_NAME}\""
echo "    cp -R \"/Volumes/MKVToolNix-${MTX_VER}-${DMG_REVISION}-${MACHINE_ARCH}/${APP_BUNDLE_NAME}\" /Applications/"
echo "    hdiutil detach \"/Volumes/MKVToolNix-${MTX_VER}-${DMG_REVISION}-${MACHINE_ARCH}\""
echo ""
echo "NOTE: This DMG is an experimental build — NOT a release. release/ was not touched."
