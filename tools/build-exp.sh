#!/bin/zsh
# tools/build-exp.sh — Build MKVToolNix from an experimental/worktree source tree.
#
# For experimental builds only. Does NOT produce release artifacts. Compiles
# the given source with the proven + experimental dep caches (experimental
# overlays proven, e.g. Qt 6.11.0 wins over 6.10.2), produces a DMG in build/
# with an experimental-specific filename, and never copies to release/.
#
# Usage: ./tools/build-exp.sh <path-to-source> [--slug NAME] [--verify-symbol SYM] [--rebuild-deps]

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

# --- BSD-find probe ---
# The script uses BSD-specific `find -perm +111` syntax. GNU find errors out
# on that flag form. If the user has homebrew gfind first on PATH and it
# shadows BSD find, this catches it at startup.
if ! command find /tmp -maxdepth 0 -perm +111 >/dev/null 2>&1; then
  echo "ERROR: 'find' in PATH appears to be GNU find, not BSD find." >&2
  echo "       This script uses BSD find flags (e.g. -perm +111)." >&2
  echo "       Ensure /usr/bin precedes homebrew prefixes in PATH, or" >&2
  echo "       resolve the conflict (e.g. 'brew unlink findutils')." >&2
  exit 1
fi

TRAPZERR() {
  echo "ERROR: build-exp.sh failed at ${funcfiletrace[1]:-line ${LINENO}} (exit code $?)" >&2
}

# SCRIPT_DIR = wrapper repo root (tools/ → parent)
SCRIPT_DIR=${0:a:h:h}

usage() {
  cat <<'USAGE'
Usage: ./tools/build-exp.sh <path-to-source> [--slug NAME] [--verify-symbol SYM] [--rebuild-deps]

Build MKVToolNix from an experimental/worktree source tree. Produces a DMG
in build/ with an experimental-specific filename. Uses proven + experimental
dep caches (experimental wins on conflicts, e.g. Qt 6.11.0 > 6.10.2).

For experimental builds only. Never copies to release/.

Arguments:
  <path-to-source>         Absolute path to a mkvtoolnix source tree
                           (e.g., a git worktree checkout).

Options:
  --slug NAME              DMG filename suffix. Defaults to basename
                           of source path (with leading "mkvtoolnix-
                           upstream-" stripped if present).
  --verify-symbol SYM      Verify the built binary contains this string
                           before declaring success. Abort if missing.
                           Intended to catch "patch didn't compile in"
                           failure mode. Example: lastProgramRunnerAudioDir
  --rebuild-deps           Allow building missing deps from source. Without
                           this flag, missing entries in the experimental
                           cache cause an immediate hard-fail (preserves
                           cache-only smart-restore semantics for fast
                           iteration). With this flag, the missing deps
                           are added to upstream's build.sh target list,
                           built fresh, and promoted to the experimental
                           cache (with a provenance manifest sidecar) for
                           future runs. Use this once when (re)populating
                           the cache; omit it for measurement runs.
  --help, -h               Show this help.
USAGE
}

# --- Arg parsing ---
SRC=""
SLUG=""
VERIFY_SYMBOL=""
REBUILD_DEPS=0
while [[ -n $1 ]]; do
  case $1 in
    --slug)
      shift
      SLUG="$1"
      ;;
    --verify-symbol)
      shift
      VERIFY_SYMBOL="$1"
      ;;
    --rebuild-deps)
      REBUILD_DEPS=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      echo "ERROR: Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -z "${SRC}" ]]; then
        SRC="$1"
      else
        echo "ERROR: Unexpected argument: $1" >&2
        exit 1
      fi
      ;;
  esac
  shift
done

if [[ -z "${SRC}" ]]; then
  echo "ERROR: source path required" >&2
  usage >&2
  exit 1
fi

# Absolutize source path
SRC=${SRC:a}
if [[ ! -d "${SRC}" ]]; then
  echo "ERROR: source path does not exist: ${SRC}" >&2
  exit 1
fi

# --- Sanity: source looks like mkvtoolnix ---
if [[ ! -f "${SRC}/configure.ac" ]] || [[ ! -d "${SRC}/src/mkvtoolnix-gui" ]] || [[ ! -f "${SRC}/packaging/macos/build.sh" ]]; then
  echo "ERROR: ${SRC} does not look like a mkvtoolnix source tree" >&2
  echo "       Expected: configure.ac, src/mkvtoolnix-gui/, packaging/macos/build.sh" >&2
  exit 1
fi

# --- Ensure git submodules are populated ---
# mkvtoolnix uses submodules for lib/libebml, lib/libmatroska, lib/fmt.
# configure fails without them. git submodule update is idempotent — fast
# no-op if already initialized. Done in SRC (which has .git), not in the
# rsync'd copy.
if [[ -d "${SRC}/.git" ]] || [[ -f "${SRC}/.git" ]]; then
  echo "==> Ensuring git submodules are initialized in ${SRC}..."
  (cd "${SRC}" && git submodule update --init --recursive)
else
  echo "WARNING: ${SRC} is not a git checkout — skipping submodule init."
  echo "         If build fails with missing libEBML/libMatroska/fmt, you need"
  echo "         to populate lib/libebml, lib/libmatroska, lib/fmt manually." >&2
fi

# --- Architecture ---
MACHINE_ARCH=$(uname -m)
if [[ "${MACHINE_ARCH}" == "arm64" ]]; then
  ARCH_LABEL="arm"
elif [[ "${MACHINE_ARCH}" == "x86_64" ]]; then
  ARCH_LABEL="intel"
else
  ARCH_LABEL="${MACHINE_ARCH}"
fi

# --- Slug defaulting ---
if [[ -z "${SLUG}" ]]; then
  SLUG="${SRC:t}"
  SLUG="${SLUG#mkvtoolnix-upstream-}"
fi
# Sanitize: allow only [A-Za-z0-9_-]
SLUG="${SLUG//[^a-zA-Z0-9_-]/-}"

# --- MTX_VER from worktree's configure.ac ---
MTX_VER=$(awk -F, '/AC_INIT/ { gsub("[][]", "", $2); print $2 }' "${SRC}/configure.ac")
if [[ -z "${MTX_VER}" ]]; then
  echo "ERROR: Could not derive MTX_VER from ${SRC}/configure.ac" >&2
  exit 1
fi

# --- Paths: honor env overrides, default to upstream's convention ---
WORK_DIR="${WORK_DIR:-${HOME}/tmp/compile}"
TARGET="${TARGET:-${HOME}/opt}"

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
VERSIONNAME="99pre-exp-${SLUG}-${BUILD_LABEL}-${BUILD_HASH}"

echo "==> build-exp.sh"
echo "    Source:      ${SRC}"
echo "    Slug:        ${SLUG}"
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

# 12-char hash of the staged build_qt configure args (only the lines inside
# the `args=(...)` array assignment in build_qt). Whitespace-normalized then
# sorted, so reformatting indent or line order doesn't perturb the hash.
#
# Source-level (not closure-level): variable references like ${TARGET} are
# hashed literally; their RUNTIME values aren't part of this fingerprint.
# That means MACOSX_DEPLOYMENT_TARGET, compiler version, SDK version are
# NOT captured here.
#
# Earlier versions captured everything in build_qt that started with `-`,
# which included `time $DEBUG cmake --build .` and `--parallel
# $DRAKETHREADS` from the cmake invocation — unstable and not actually
# configure args.
_qt_args_hash() {
  local build_sh="$1"
  command awk '
    /^function build_qt/ { in_qt = 1 }
    in_qt && /^[[:space:]]*args=\(/ { in_args = 1; next }
    in_args && /^[[:space:]]*\)/ { in_args = 0; in_qt = 0; next }
    in_args { print }
  ' "$build_sh" \
    | command sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | command grep -v '^$' \
    | command sort \
    | command shasum -a 256 \
    | command awk '{print substr($1, 1, 12)}'
}

# 12-char hash of patches relevant to this dep. For Qt, hashes the contents
# of patches/qt-patches/*.patch (concatenated in sorted order so filename
# order is deterministic). For other deps, returns "none" — there are no
# per-dep patches outside Qt currently. Returns "none" if no patches apply.
#
# This complements _qt_args_hash to give a more complete cache identity:
# args_hash captures the configure-args structure; patch_state_hash
# captures the source-modification state. Restore-time validation can
# refuse caches whose patch_state_hash doesn't match current state.
_patch_state_hash() {
  local spec_name="$1"
  case "$spec_name" in
    qt)
      local patches_dir="${SCRIPT_DIR}/patches/qt-patches"
      if [[ -d "$patches_dir" ]]; then
        local files
        files=$(command find "$patches_dir" -name '*.patch' -type f 2>/dev/null | command sort)
        if [[ -n "$files" ]]; then
          # No `2>/dev/null` here: loud failure is preferable. The original
          # implementation used `/usr/bin/cat` (which does not exist on
          # macOS — cat is at /bin/cat) plus `2>/dev/null`, producing the
          # empty-input SHA-256 prefix `e3b0c44298fc...` for every patch set
          # and masking patch-state changes (commit 37683b1 fixed it).
          # Subsequent portability pass replaced absolute paths with
          # `command <tool>` to remove the path-drift bug class entirely.
          print "$files" | command xargs command cat \
            | command shasum -a 256 \
            | command awk '{print substr($1, 1, 12)}'
          return
        fi
      fi
      print "none"
      ;;
    *)
      # No per-dep patches outside Qt currently. If you add patch directories
      # for other deps, extend this case statement.
      print "none"
      ;;
  esac
}

# Reads a single field from a manifest sidecar via grep+sed. Returns empty
# if the field is missing.
_manifest_field() {
  local sidecar="$1" field="$2"
  command grep -oE "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$sidecar" 2>/dev/null \
    | command sed -E 's/.*"([^"]*)"$/\1/'
}
_manifest_int_field() {
  local sidecar="$1" field="$2"
  command grep -oE "\"${field}\"[[:space:]]*:[[:space:]]*[0-9]+" "$sidecar" 2>/dev/null \
    | command awk '{print $NF}'
}

# Reads a dep cache manifest sidecar; prints a short one-line summary
# suitable for the restore log, or "absent" / "malformed" sentinel.
_dep_manifest_summary() {
  local sidecar="$1"
  if [[ ! -f "$sidecar" ]]; then
    print "absent"
    return
  fi
  local args_hash patch_hash built_at dylibs
  args_hash=$(_manifest_field "$sidecar" "configure_args_hash")
  patch_hash=$(_manifest_field "$sidecar" "patch_state_hash")
  built_at=$(_manifest_field "$sidecar" "built_at")
  dylibs=$(_manifest_int_field "$sidecar" "dylib_count")
  if [[ -z "$built_at" ]]; then
    print "malformed"
    return
  fi
  printf 'args=%s patches=%s built=%s dylibs=%s' "${args_hash:-n/a}" "${patch_hash:-n/a}" "${built_at}" "${dylibs:-?}"
}

# Validates a dep cache manifest against expected spec values. Refuses on
# critical mismatches (schema_version, spec_name, package, source_sha256).
# Drift on optional fields (configure_args_hash, patch_state_hash) is a
# warning, not a refusal — those are advisory.
#
# Args: $1=manifest_path, $2=expected_spec_name, $3=expected_package,
#       $4=expected_source_sha256 (may be empty)
# Stdout: human-readable validation message
# Exit:   0=valid, 1=REFUSE (critical mismatch), 2=WARN (drift on advisory fields)
_validate_dep_manifest() {
  local manifest="$1" exp_spec="$2" exp_pkg="$3" exp_src_sha="$4"
  if [[ ! -f "$manifest" ]]; then
    print "no manifest sidecar"
    return 1
  fi

  local schema spec pkg src_sha
  schema=$(_manifest_int_field "$manifest" "schema_version")
  spec=$(_manifest_field "$manifest" "spec_name")
  pkg=$(_manifest_field "$manifest" "package")
  src_sha=$(_manifest_field "$manifest" "source_sha256")

  if [[ -z "$schema" ]]; then
    print "REFUSE: malformed manifest (no schema_version)"
    return 1
  fi
  if [[ "$schema" != "1" ]]; then
    print "REFUSE: schema_version=${schema} (this build-exp.sh handles only v1)"
    return 1
  fi
  if [[ "$spec" != "$exp_spec" ]]; then
    print "REFUSE: spec_name=${spec} (expected ${exp_spec})"
    return 1
  fi
  if [[ "$pkg" != "$exp_pkg" ]]; then
    print "REFUSE: package=${pkg} (expected ${exp_pkg})"
    return 1
  fi
  if [[ -n "$exp_src_sha" && "$src_sha" != "$exp_src_sha" ]]; then
    print "REFUSE: source_sha256 mismatch (cache built from different source tarball)"
    return 1
  fi

  # Optional/advisory drift checks (warn, don't refuse).
  local cur_args="" manifest_args drift=()
  if [[ "$exp_spec" == "qt" && -n "${SRC:-}" && -f "${SRC}/packaging/macos/build.sh" ]]; then
    cur_args=$(_qt_args_hash "${SRC}/packaging/macos/build.sh")
  fi
  manifest_args=$(_manifest_field "$manifest" "configure_args_hash")
  if [[ -n "$cur_args" && -n "$manifest_args" && "$cur_args" != "$manifest_args" ]]; then
    drift+=("args_hash:${manifest_args}→${cur_args}")
  fi

  local cur_patch manifest_patch
  cur_patch=$(_patch_state_hash "$exp_spec")
  manifest_patch=$(_manifest_field "$manifest" "patch_state_hash")
  if [[ -n "$cur_patch" && -n "$manifest_patch" && "$cur_patch" != "$manifest_patch" ]]; then
    drift+=("patch_state:${manifest_patch}→${cur_patch}")
  fi

  if [[ ${#drift[@]} -gt 0 ]]; then
    print "DRIFT: ${(j:, :)drift}"
    return 2
  fi

  print "OK (args=${manifest_args:-n/a} patches=${manifest_patch:-n/a})"
  return 0
}

# Writes the dep cache manifest sidecar after promoting a freshly-built dep.
# Args: $1=spec_name (qt|zlib|...), $2=package (e.g. qt-everywhere-src-6.11.0),
#       $3=spec_tarball (e.g. qt-everywhere-src-6.11.0.tar.xz),
#       $4=source_sha256, $5=output_path
_write_dep_manifest() {
  local spec_name="$1" package="$2" tarball="$3" source_sha="$4" out="$5"
  local args_hash="" dylib_count target_lib_dir patch_hash
  # configure_args_hash is Qt-specific (it reads build_qt's args=(...)).
  # Other deps don't have a comparable structured-args list in build.sh, so
  # leave the field empty rather than recording a misleading Qt hash for
  # zlib/etc. (Earlier versions emitted the Qt hash for all deps.)
  if [[ "$spec_name" == "qt" ]]; then
    args_hash=$(_qt_args_hash "${FORK_BUILD_DIR}/packaging/macos/build.sh")
  fi
  patch_hash=$(_patch_state_hash "$spec_name")
  target_lib_dir="${TARGET}/lib"
  dylib_count=0
  if [[ "$spec_name" == "qt" && -d "$target_lib_dir" ]]; then
    dylib_count=$(command find "$target_lib_dir" -name 'libQt6*.dylib' -not -type l 2>/dev/null | command wc -l | command tr -d ' ')
  fi
  local wrapper_branch wrapper_sha
  wrapper_branch=$(git -C "${SCRIPT_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  wrapper_sha=$(git -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  cat > "$out" <<EOF
{
  "schema_version": 1,
  "kind": "dep_cache",
  "spec_name": $(_json_str "$spec_name"),
  "package": $(_json_str "$package"),
  "spec_tarball": $(_json_str "$tarball"),
  "source_sha256": $(_json_str "$source_sha"),
  "configure_args_hash": $(_json_str "$args_hash"),
  "patch_state_hash": $(_json_str "$patch_hash"),
  "built_at": $(_json_str "$(_iso_utc)"),
  "built_by": {
    "tool": "tools/build-exp.sh",
    "wrapper_branch": $(_json_str "$wrapper_branch"),
    "wrapper_sha": $(_json_str "$wrapper_sha")
  },
  "dylib_count": ${dylib_count},
  "host": $(_host_json)
}
EOF
}

# --- Wipe workspace (preserve proven, proven-experimental, source, staging) ---
echo "==> Wiping workspace TARGET (preserve proven/, proven-experimental/, source/, staging/)..."
for item in "${TARGET}"/*; do
  case "${item:t}" in
    proven|proven-experimental|source|staging) continue ;;
  esac
  [[ -e "${item}" ]] && echo "    rm -rf ${item:t}" && command rm -rf "${item}"
done
mkdir -p "${TARGET}/include" "${TARGET}/lib" "${TARGET}/bin" "${TARGET}/packages"

# Clean out prior experimental-build scratch dir for this MTX_VER
FORK_BUILD_DIR="${WORK_DIR}/mkvtoolnix-${MTX_VER}"
if [[ -d "${FORK_BUILD_DIR}" ]]; then
  echo "    rm -rf ${FORK_BUILD_DIR:t} (prior experimental-build scratch)"
  command rm -rf "${FORK_BUILD_DIR}"
fi

# Remove prior DMG staging for this version
command rm -rf "${WORK_DIR}/dmg-${MTX_VER}" "${WORK_DIR}/MKVToolNix-${MTX_VER}.dmg" 2>/dev/null || true

# --- Restore deps: proven first, experimental overlays on top ---
PROVEN_DIR="${TARGET}/proven/${ARCH_LABEL}"
EXPERIMENTAL_DIR="${TARGET}/proven-experimental/${ARCH_LABEL}"

if [[ ! -d "${PROVEN_DIR}" ]]; then
  echo "ERROR: Proven cache not found at ${PROVEN_DIR}" >&2
  echo "       Run './build-local.sh --restore-cache' first." >&2
  exit 1
fi

# Spec-aware restore: read the worktree's specs.sh to discover which exact
# package name is wanted for each dependency. For each expected package, pick
# experimental if it has the matching filename, else proven. Skip proven packages
# whose names don't match the spec (e.g., older Qt/zlib versions that would
# otherwise bundle alongside experimental and bloat the DMG).
echo "==> Discovering expected packages from worktree specs.sh..."
_SAVED_OPTS_RESTORE=$(setopt | tr '\n' ' ')
source "${SRC}/packaging/macos/specs.sh"
setopt ${=_SAVED_OPTS_RESTORE} 2>/dev/null
set -e

EXPECTED_PACKAGES=()
EXPECTED_TARGETS=()
EXPECTED_TARBALLS=()
EXPECTED_SHAS=()
# Deliberately omit spec_curl — mkvtoolnix compile doesn't link curl, and the
# wrapper's proven cache predates its addition to upstream specs.
# spec_NAME → build_NAME target → "NAME" (no "spec_" prefix). Verified against
# upstream's build.sh dispatcher (`while [[ -n $1 ]]; do build_$1; shift; done`).
for spec_var in spec_autoconf spec_automake spec_pkgconfig spec_libiconv \
                spec_cmake spec_ogg spec_vorbis spec_flac spec_zlib spec_gettext \
                spec_cmark spec_gmp spec_boost spec_qt; do
  filename="${${(P)spec_var}[1]}"
  [[ -z "${filename}" ]] && continue
  pkg="${filename%%.tar.*}"
  EXPECTED_PACKAGES+=("${pkg}")
  EXPECTED_TARGETS+=("${spec_var#spec_}")
  EXPECTED_TARBALLS+=("${filename}")
  # spec_arr[3] is the source SHA256 (when present). Empty if not.
  src_sha="${${(P)spec_var}[3]}"
  EXPECTED_SHAS+=("${src_sha:-}")
done
# Normalize zlib filename — specs use "zlib-vN.N.N" in source-tarball URL, but
# the built package is named "zlib-N.N.N" (no "v"). Matches build-local.sh.
EXPECTED_PACKAGES=("${EXPECTED_PACKAGES[@]/zlib-v/zlib-}")

echo "==> Expected packages (${#EXPECTED_PACKAGES[@]}): ${EXPECTED_PACKAGES[*]}"

echo "==> Restoring packages (experimental wins on match; sentinels validated)..."
restored=0
from_experimental=0
from_proven=0
missing=()
missing_targets=()
DEPS_JSON_PARTS=()
unsentineled_experimental=()
drifting_caches=()
# Defense-in-depth: zsh's `{1..0}` produces a descending range (1, 0) rather
# than an empty sequence, so guard against an empty EXPECTED_PACKAGES.
if [[ ${#EXPECTED_PACKAGES[@]} -eq 0 ]]; then
  echo "ERROR: EXPECTED_PACKAGES is empty — specs.sh enumeration failed?" >&2
  exit 1
fi
for i in {1..${#EXPECTED_PACKAGES[@]}}; do
  pkg="${EXPECTED_PACKAGES[$i]}"
  target="${EXPECTED_TARGETS[$i]}"
  exp_tarball="${EXPERIMENTAL_DIR}/${pkg}.tar.gz"
  proven_tarball="${PROVEN_DIR}/${pkg}.tar.gz"
  if [[ -f "${exp_tarball}" ]]; then
    manifest_path="${exp_tarball}.manifest.json"
    if [[ ! -f "${manifest_path}" ]]; then
      echo "    ${pkg} (experimental, NO PROVENANCE MANIFEST)"
      unsentineled_experimental+=("${pkg}")
      summary="absent"
    else
      # Capture validation result via if/else so set -e doesn't treat the
      # function's non-zero return (1=REFUSE, 2=DRIFT) as a fatal error.
      # Plain `var=$(...)` triggers errexit on non-zero substitution in zsh.
      if validation_msg=$(_validate_dep_manifest "${manifest_path}" "${target}" "${pkg}" "${EXPECTED_SHAS[$i]}"); then
        validation_result=0
      else
        validation_result=$?
      fi
      if [[ ${validation_result} -eq 1 ]]; then
        echo "" >&2
        echo "ERROR: cache validation refused ${pkg}:" >&2
        echo "       ${validation_msg}" >&2
        echo "" >&2
        echo "       The cached tarball does not match the expected build inputs." >&2
        echo "       To replace it, remove all three sidecar files:" >&2
        echo "         rm '${exp_tarball}'" >&2
        echo "         rm '${exp_tarball}.sha256'" >&2
        echo "         rm '${manifest_path}'" >&2
        echo "       Then re-run with --rebuild-deps to populate cleanly." >&2
        exit 1
      elif [[ ${validation_result} -eq 2 ]]; then
        echo "    ${pkg} (experimental, ${validation_msg})"
        drifting_caches+=("${pkg}")
        summary="${validation_msg}"
      else
        echo "    ${pkg} (experimental, ${validation_msg})"
        summary="${validation_msg}"
      fi
    fi
    (cd "${TARGET}" && tar xzf "${exp_tarball}")
    from_experimental=$((from_experimental + 1))
    restored=$((restored + 1))
    DEPS_JSON_PARTS+=("{\"spec_name\":$(_json_str "${target}"),\"package\":$(_json_str "${pkg}"),\"from\":\"experimental_cache\",\"manifest_summary\":$(_json_str "${summary}")}")
  elif [[ -f "${proven_tarball}" ]]; then
    echo "    ${pkg}"
    (cd "${TARGET}" && tar xzf "${proven_tarball}")
    from_proven=$((from_proven + 1))
    restored=$((restored + 1))
    DEPS_JSON_PARTS+=("{\"spec_name\":$(_json_str "${target}"),\"package\":$(_json_str "${pkg}"),\"from\":\"proven_cache\"}")
  else
    echo "    MISSING: ${pkg}  (target: ${target})"
    missing+=("${pkg}")
    missing_targets+=("${target}")
    DEPS_JSON_PARTS+=("{\"spec_name\":$(_json_str "${target}"),\"package\":$(_json_str "${pkg}"),\"from\":\"built_from_source\"}")
  fi
done

# Special-case docbook-xsl — not a standard spec name, handled separately.
if [[ -f "${EXPERIMENTAL_DIR}/docbook-xsl.tar.gz" ]]; then
  echo "    docbook-xsl (experimental)"
  (cd "${TARGET}" && tar xzf "${EXPERIMENTAL_DIR}/docbook-xsl.tar.gz")
  from_experimental=$((from_experimental + 1))
elif [[ -f "${PROVEN_DIR}/docbook-xsl.tar.gz" ]]; then
  echo "    docbook-xsl"
  (cd "${TARGET}" && tar xzf "${PROVEN_DIR}/docbook-xsl.tar.gz")
  from_proven=$((from_proven + 1))
fi

echo "==> Restored ${restored} packages (${from_experimental} experimental, ${from_proven} proven)."
if [[ ${#unsentineled_experimental[@]} -gt 0 ]]; then
  echo "" >&2
  echo "WARN: ${#unsentineled_experimental[@]} experimental cache entry(ies) lack provenance manifests:" >&2
  for u in "${unsentineled_experimental[@]}"; do echo "      - ${u}" >&2; done
  echo "      These tarballs may have been built outside tools/build-exp.sh and" >&2
  echo "      could carry unintended configure-time decisions. To refresh them," >&2
  echo "      first remove them from ${EXPERIMENTAL_DIR}/, then re-run with" >&2
  echo "      --rebuild-deps. (--rebuild-deps only rebuilds MISSING entries;" >&2
  echo "      existing-but-unsentineled tarballs must be removed first.)" >&2
  echo "" >&2
fi
if [[ ${#drifting_caches[@]} -gt 0 ]]; then
  echo "" >&2
  echo "WARN: ${#drifting_caches[@]} experimental cache entry(ies) show drift from current state:" >&2
  for d in "${drifting_caches[@]}"; do echo "      - ${d}" >&2; done
  echo "      The cache was built with different configure args or patch state" >&2
  echo "      than the current source. The build will proceed (drift is" >&2
  echo "      advisory), but consider --rebuild-deps to refresh if accuracy" >&2
  echo "      matters for this measurement." >&2
  echo "" >&2
fi
if [[ ${#missing[@]} -gt 0 ]]; then
  if [[ ${REBUILD_DEPS} -eq 1 ]]; then
    echo "==> ${#missing[@]} dep(s) will be built from source: ${missing_targets[*]}"
    echo "    (--rebuild-deps in effect; freshly-built deps will be promoted to" \
         "experimental cache with provenance manifests after build success.)"
  else
    echo "" >&2
    echo "ERROR: ${#missing[@]} expected package(s) missing from both caches:" >&2
    for m in "${missing[@]}"; do echo "       - ${m}" >&2; done
    echo "" >&2
    echo "       Smart-restore semantics require all expected packages to be in" >&2
    echo "       proven/ or proven-experimental/. To populate the experimental" >&2
    echo "       cache by building these from source (one-time per Qt/zlib bump)," >&2
    echo "       re-run with --rebuild-deps:" >&2
    echo "" >&2
    cmd_recommendation="$0 ${SRC} --slug ${SLUG} --rebuild-deps"
    [[ -n "${VERIFY_SYMBOL}" ]] && cmd_recommendation+=" --verify-symbol ${VERIFY_SYMBOL}"
    echo "         ${cmd_recommendation}" >&2
    echo "" >&2
    exit 1
  fi
fi

# --- Stage source into WORK_DIR (upstream build.sh expects ${CMPL}/mkvtoolnix-${MTX_VER}) ---
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

# --- Stage wrapper's config into the staged packaging dir ---
# Upstream build.sh sources packaging/macos/config.local.sh if present. We
# prefer config.exp.local.sh (experimental-only: no QTVER pin, defers to
# upstream specs.sh) and fall back to config.local.sh if the experimental
# file is absent. Production build-local.sh continues to consume
# config.local.sh unchanged; only experimental builds get the
# exp.local.sh substitution.
WRAPPER_CONFIG=""
if [[ -f "${SCRIPT_DIR}/config/config.exp.local.sh" ]]; then
  WRAPPER_CONFIG="${SCRIPT_DIR}/config/config.exp.local.sh"
  echo "==> Staging config.exp.local.sh as packaging/macos/config.local.sh..."
elif [[ -f "${SCRIPT_DIR}/config/config.local.sh" ]]; then
  WRAPPER_CONFIG="${SCRIPT_DIR}/config/config.local.sh"
  echo "==> Staging config.local.sh as packaging/macos/config.local.sh (no experimental config found)..."
fi
if [[ -n "${WRAPPER_CONFIG}" ]]; then
  STAGED_CONFIG="${FORK_BUILD_DIR}/packaging/macos/config.local.sh"
  command cp "${WRAPPER_CONFIG}" "${STAGED_CONFIG}"
fi

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
# Verify the substitution actually happened
if ! command grep -q "VERSIONNAME = \"${VERSIONNAME}\"" "${VERSION_FILE}"; then
  echo "ERROR: VERSIONNAME injection failed — source unchanged." >&2
  exit 1
fi

# --- Environment for upstream build.sh ---
# Source upstream's config.sh (provides CMPL, RAKE, MACOSX_DEPLOYMENT_TARGET, etc.)
# then the wrapper config (already resolved to WRAPPER_CONFIG above —
# config.exp.local.sh preferred, falls back to config.local.sh).
#
# Preserve any user-provided TARGET/SRCDIR env overrides. Upstream's config.sh
# unconditionally writes `export TARGET=$HOME/opt`, `export SRCDIR=$HOME/opt/source`,
# `export PACKAGE_DIR=$HOME/opt/packages`. Without this guard,
# `TARGET=/Volumes/Fast/opt ./tools/build-exp.sh ...` silently mixes dep
# trees: cache restore (which ran BEFORE this block, with the override
# honored) extracts into /Volumes/Fast/opt while build links against
# $HOME/opt. The restoration below re-asserts the user's choice and
# re-anchors PACKAGE_DIR so the promote step finds tarballs in the right
# place.
_saved_target="${TARGET:-}"
_saved_srcdir="${SRCDIR:-}"
_SAVED_OPTS=$(setopt | tr '\n' ' ')
source "${FORK_BUILD_DIR}/packaging/macos/config.sh"
if [[ -n "${WRAPPER_CONFIG}" ]]; then
  source "${WRAPPER_CONFIG}"
fi
if [[ -n "${_saved_target}" ]]; then
  export TARGET="${_saved_target}"
  export PACKAGE_DIR="${TARGET}/packages"
  [[ -z "${_saved_srcdir}" ]] && export SRCDIR="${TARGET}/source"
fi
if [[ -n "${_saved_srcdir}" ]]; then
  export SRCDIR="${_saved_srcdir}"
fi
unset _saved_target _saved_srcdir
# Re-enable our options after sourced files may have changed them
setopt ${=_SAVED_OPTS} 2>/dev/null
set -e

# Normalize paths — upstream config.sh hardcodes $HOME/tmp/compile; honor our WORK_DIR if different
export CMPL="${WORK_DIR}"
export TARGET
export SRCDIR="${SRCDIR:-${HOME}/opt/source}"
export MTX_VER
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
echo "    NO_EXTRACTION: ${NO_EXTRACTION}"

# --- Generate ./configure via autogen.sh ---
# Git checkouts don't include a pre-generated `configure`; release tarballs do.
# autogen.sh produces it via autoconf + automake (both present in proven cache).
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
# NO_EXTRACTION must be unset for dep builds (they extract their own source
# from ${SRCDIR}) but set for build_mkvtoolnix (which would wipe our staged
# source if allowed to extract). Two-phase invocation keeps the semantics
# clean per phase.
echo ""
cd "${FORK_BUILD_DIR}/packaging/macos"
if [[ ${#missing_targets[@]} -gt 0 ]]; then
  echo "==> Building missing deps from source: ${missing_targets[*]}"
  echo "    (NO_EXTRACTION unset for this phase — deps must extract their tarballs)"
  ( unset NO_EXTRACTION; ./build.sh ${missing_targets} )
fi

echo ""
echo "==> Building mkvtoolnix (NO_EXTRACTION=1; staged source preserved)..."
./build.sh mkvtoolnix

echo ""
echo "==> Packaging DMG..."
./build.sh dmg

# --- DMG + binary verification ---
DMG_PATH="${WORK_DIR}/MKVToolNix-${MTX_VER}.dmg"
APP_BUNDLE="${WORK_DIR}/dmg-${MTX_VER}/MKVToolNix-${MTX_VER}.app"
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
done < <(command find "${APP_BUNDLE}/Contents/MacOS" \( -name "*.dylib" -o -type f -perm +111 \) -not -type d -print0 2>/dev/null)
if [[ ${arch_errors} -eq 0 ]] && [[ ${arch_checked} -gt 0 ]]; then
  echo "    PASS: all ${arch_checked} binaries/dylibs are ${MACHINE_ARCH}"
elif [[ ${arch_errors} -gt 0 ]]; then
  VERIFY_ISSUES=$((VERIFY_ISSUES + arch_errors))
fi

# 2. Size sanity (fork builds may differ from production, so wider range)
app_bytes=$(command find "${APP_BUNDLE}" -type f -exec command stat -f '%z' {} + 2>/dev/null | awk '{s+=$1} END {print s}')
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

DMG_FINAL_NAME="MKVToolNix-${MTX_VER}-${ARCH_LABEL}-${BUILD_LABEL}-${SLUG}-${BUILD_HASH}.dmg"
command cp "${DMG_PATH}" "${BUILD_DIR}/${DMG_FINAL_NAME}"
(cd "${BUILD_DIR}" && shasum -a 256 "${DMG_FINAL_NAME}" > "${DMG_FINAL_NAME}.sha256")
DMG_FINAL_PATH="${BUILD_DIR}/${DMG_FINAL_NAME}"

# --- Promote freshly-built deps to experimental cache (if --rebuild-deps) ---
# Each successfully-built dep has its install tarball deposited in PACKAGE_DIR
# by upstream's build_tarball helper. We copy it into the experimental cache
# and write a provenance manifest sidecar so future restore-time checks can
# verify its origin.
PROMOTED_DEPS=()
if [[ ${REBUILD_DEPS} -eq 1 ]] && [[ ${#missing_targets[@]} -gt 0 ]]; then
  echo ""
  echo "==> Promoting freshly-built deps to experimental cache..."
  mkdir -p "${EXPERIMENTAL_DIR}"
  for j in {1..${#missing_targets[@]}}; do
    target="${missing_targets[$j]}"
    pkg=""
    tarball=""
    src_sha=""
    # Look up the package and source SHA for this target via the parallel arrays.
    for k in {1..${#EXPECTED_TARGETS[@]}}; do
      if [[ "${EXPECTED_TARGETS[$k]}" == "${target}" ]]; then
        pkg="${EXPECTED_PACKAGES[$k]}"
        tarball="${EXPECTED_TARBALLS[$k]}"
        src_sha="${EXPECTED_SHAS[$k]}"
        break
      fi
    done
    if [[ -z "${pkg}" ]]; then
      echo "    WARN: could not map target '${target}' to a package; skipping promote." >&2
      continue
    fi
    # PACKAGE_DIR was set via upstream's config.sh (= ${TARGET}/packages by default).
    src_built="${PACKAGE_DIR:-${TARGET}/packages}/${pkg}.tar.gz"
    if [[ ! -f "${src_built}" ]]; then
      echo "    WARN: expected build_tarball output ${src_built} missing; skipping promote." >&2
      continue
    fi
    dest="${EXPERIMENTAL_DIR}/${pkg}.tar.gz"
    command cp "${src_built}" "${dest}"
    (cd "${EXPERIMENTAL_DIR}" && shasum -a 256 "${pkg}.tar.gz" > "${pkg}.tar.gz.sha256")
    _write_dep_manifest "${target}" "${pkg}" "${tarball}" "${src_sha}" "${dest}.manifest.json"
    PROMOTED_DEPS+=("${pkg}")
    echo "    promoted: ${pkg}.tar.gz (+ .sha256, + .manifest.json)"
  done
fi

# --- Write DMG sidecar manifest ---
# Captures full build provenance: source refs, deps used, host machine specs
# (non-identifying), patches, timing, verification results. Sits alongside
# the DMG and its .sha256 in build/.
_PATCH_DIR="${SCRIPT_DIR}/patches"
PATCHES_JSON="["
_first_patch=1
if [[ -d "${_PATCH_DIR}" ]]; then
  for p in "${_PATCH_DIR}"/*.patch(N) "${_PATCH_DIR}"/qt-patches/*.patch(N); do
    [[ -f "$p" ]] || continue
    [[ ${_first_patch} -eq 1 ]] && _first_patch=0 || PATCHES_JSON+=", "
    p_sha=$(command shasum -a 256 "$p" | command awk '{print $1}')
    p_rel="${p#${SCRIPT_DIR}/}"
    PATCHES_JSON+="{\"name\":$(_json_str "${p_rel}"),\"sha256\":$(_json_str "${p_sha}")}"
  done
fi
PATCHES_JSON+="]"

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

_dmg_size_bytes=$(command stat -f %z "${DMG_FINAL_PATH}")
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

_args_hash=$(_qt_args_hash "${FORK_BUILD_DIR}/packaging/macos/build.sh")
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
    "rebuild_deps_used": $([[ ${REBUILD_DEPS} -eq 1 ]] && echo "true" || echo "false")
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
  "configure_args_hash": $(_json_str "${_args_hash}"),
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
if [[ ${#PROMOTED_DEPS[@]} -gt 0 ]]; then
  echo "  Promoted deps: ${PROMOTED_DEPS[*]} → ${EXPERIMENTAL_DIR}"
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
echo "    cp -R \"/Volumes/MKVToolNix-${MTX_VER}/MKVToolNix-${MTX_VER}.app\" /Applications/"
echo "    hdiutil detach \"/Volumes/MKVToolNix-${MTX_VER}\""
echo ""
echo "NOTE: This DMG is an experimental build — NOT a release. release/ was not touched."
