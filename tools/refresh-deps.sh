#!/bin/zsh
# Rebuild only the dependencies whose cached build no longer matches a release
# tag, then repromote them. Leaves every other cached package untouched.
#
# build-local.sh refuses a cache that contradicts the tag and names the
# offenders; this is what fixes them without a full from-source rebuild. It
# lives here rather than in build-local.sh so the release path keeps its
# all-or-nothing restore and stays simple.
#
# Usage: ./tools/refresh-deps.sh <release-tag> [--dry-run]

if [[ -z "${ZSH_VERSION}" ]]; then
  echo "ERROR: This script requires zsh. Run it with: ./tools/refresh-deps.sh" >&2
  exit 1
fi

set -e
setopt NULL_GLOB
unalias -a 2>/dev/null || true

SCRIPT_DIR=${0:a:h:h}
UPSTREAM_URL="https://codeberg.org/mbunkus/mkvtoolnix.git"
WORK_DIR=${WORK_DIR:-$HOME/tmp/compile}
TARGET=${TARGET:-$HOME/opt}
CLONE_DIR="${WORK_DIR}/mkvtoolnix-src"
DRY_RUN=0
TAG=""

while [[ -n $1 ]]; do
  case $1 in
    --dry-run) DRY_RUN=1 ;;
    --help|-h)
      echo "Usage: ./tools/refresh-deps.sh <release-tag> [--dry-run]"
      echo ""
      echo "Rebuilds only the cached dependencies that no longer match the tag."
      echo "  --dry-run   Report what would be rebuilt and exit."
      exit 0
      ;;
    -*) echo "ERROR: unknown option: $1" >&2; exit 1 ;;
    *)  TAG="$1" ;;
  esac
  shift
done

if [[ -z "${TAG}" ]]; then
  echo "ERROR: release tag required (e.g. release-101.0)" >&2
  exit 1
fi

MACHINE_ARCH=$(uname -m)
case "${MACHINE_ARCH}" in
  arm64)  ARCH_LABEL="arm" ;;
  x86_64) ARCH_LABEL="intel" ;;
  *)      ARCH_LABEL="${MACHINE_ARCH}" ;;
esac
PROVEN_DIR="${TARGET}/proven/${ARCH_LABEL}"
echo "==> refresh-deps: ${TAG} on ${MACHINE_ARCH} (${ARCH_LABEL})"

if [[ ! -d "${PROVEN_DIR}" ]]; then
  echo "ERROR: no proven cache at ${PROVEN_DIR}" >&2
  echo "       Populate it first: ./build-local.sh --restore-cache" >&2
  exit 1
fi

# --- Clone at the tag and verify its signature -------------------------------
# Same trust root as build-local.sh: specs.sh is only meaningful if the tag it
# came from is signed by the pinned key.
if [[ ! -d "${CLONE_DIR}/.git" ]]; then
  echo "==> Cloning upstream ${TAG}..."
  git clone --depth 1 --branch "${TAG}" "${UPSTREAM_URL}" "${CLONE_DIR}"
else
  CURRENT_TAG=$(git -C "${CLONE_DIR}" describe --tags --exact-match 2>/dev/null || true)
  if [[ "${CURRENT_TAG}" != "${TAG}" ]]; then
    echo "==> Clone is on ${CURRENT_TAG:-unknown}, need ${TAG}. Re-cloning..."
    command rm -rf "${CLONE_DIR}"
    git clone --depth 1 --branch "${TAG}" "${UPSTREAM_URL}" "${CLONE_DIR}"
  fi
fi
git -C "${CLONE_DIR}" checkout -- .
git -C "${CLONE_DIR}" clean -fd -q

echo "==> Verifying upstream tag signature..."
GPG_TAG_DIR=$(mktemp -d)
gpg --homedir "${GPG_TAG_DIR}" --batch --quiet \
  --import "${SCRIPT_DIR}/tools/mbunkus-pubkey.asc" 2>/dev/null
verify_output=$(GNUPGHOME="${GPG_TAG_DIR}" \
  git -C "${CLONE_DIR}" verify-tag --raw "${TAG}" 2>&1 || true)
command rm -rf "${GPG_TAG_DIR}"
if ! echo "${verify_output}" | command grep -q "GOODSIG"; then
  echo "ERROR: tag signature verification FAILED for ${TAG}" >&2
  exit 1
fi
echo "==> Verified: tag ${TAG} signed by the pinned mbunkus key"

# --- Source specs and derive the parallel arrays -----------------------------
_SAVED_TARGET="${TARGET}"; _SAVED_WORK_DIR="${WORK_DIR}"
_SAVED_OPTS=$(setopt | tr '\n' ' ')
source "${CLONE_DIR}/packaging/macos/config.sh"
test -f "${CLONE_DIR}/packaging/macos/config.local.sh" && source "${CLONE_DIR}/packaging/macos/config.local.sh"
source "${CLONE_DIR}/packaging/macos/specs.sh"
setopt ${=_SAVED_OPTS} 2>/dev/null
set -e
TARGET="${_SAVED_TARGET}"; WORK_DIR="${_SAVED_WORK_DIR}"

EXPECTED_SPEC_VARS=(
  spec_autoconf spec_automake spec_pkgconfig spec_libiconv
  spec_cmake spec_ogg spec_vorbis spec_flac spec_zlib spec_gettext
  spec_cmark spec_gmp spec_boost spec_qt spec_gpg
)
EXPECTED_PACKAGES=(); EXPECTED_TARGETS=(); EXPECTED_TARBALLS=(); EXPECTED_SHAS=()
for spec_var in "${EXPECTED_SPEC_VARS[@]}"; do
  filename="${${(P)spec_var}[1]}"
  if [[ -z "${filename}" ]]; then
    echo "ERROR: ${spec_var} not found in specs.sh — upstream may have renamed it" >&2
    exit 1
  fi
  EXPECTED_PACKAGES+=("${filename%%.tar.*}")
  EXPECTED_TARGETS+=("${spec_var#spec_}")
  EXPECTED_TARBALLS+=("${filename}")
  EXPECTED_SHAS+=("${${(P)spec_var}[3]:-}")
done
EXPECTED_PACKAGES=("${EXPECTED_PACKAGES[@]/zlib-v/zlib-}")

# --- Manifest helpers (duplicated per the self-contained-script policy) ------
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


# Writes the provenance manifest for a repromoted package. Same schema and kind
# as build-local.sh's, so build-local.sh's validator accepts what this produces.
_refresh_write_manifest() {
  local package="$1" out="$2"
  local i idx="" spec tarball src_sha args_hash="" patch_hash wb ws
  for i in {1..${#EXPECTED_PACKAGES[@]}}; do
    [[ "${EXPECTED_PACKAGES[$i]}" == "${package}" ]] && { idx=$i; break; }
  done
  if [[ -z "${idx}" ]]; then
    echo "ERROR: ${package} is not in this tag's spec set" >&2
    return 1
  fi
  spec="${EXPECTED_TARGETS[$idx]}"
  tarball="${EXPECTED_TARBALLS[$idx]}"
  src_sha="${EXPECTED_SHAS[$idx]}"
  if [[ "${spec}" == "qt" && -f "${CLONE_DIR}/packaging/macos/build.sh" ]]; then
    args_hash=$(_qt_args_hash "${CLONE_DIR}/packaging/macos/build.sh")
  fi
  patch_hash=$(_patch_state_hash "${spec}")
  wb=$(git -C "${SCRIPT_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  ws=$(git -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  cat > "${out}" <<EOF
{
  "schema_version": 1,
  "kind": "proven_cache",
  "spec_name": $(_json_str "${spec}"),
  "package": $(_json_str "${package}"),
  "spec_tarball": $(_json_str "${tarball}"),
  "source_sha256": $(_json_str "${src_sha}"),
  "configure_args_hash": $(_json_str "${args_hash}"),
  "patch_state_hash": $(_json_str "${patch_hash}"),
  "built_at": $(_json_str "$(_iso_utc)"),
  "built_by": {
    "tool": "tools/refresh-deps.sh",
    "upstream_tag": $(_json_str "${TAG}"),
    "wrapper_branch": $(_json_str "${wb}"),
    "wrapper_sha": $(_json_str "${ws}")
  },
  "host": $(_host_json)
}
EOF
  if command -v python3 >/dev/null 2>&1; then
    if ! python3 -m json.tool "${out}" >/dev/null 2>&1; then
      echo "ERROR: manifest for ${package} is not valid JSON" >&2
      command rm -f "${out}"
      return 1
    fi
  fi
}

# --- Detect drift ------------------------------------------------------------
echo "==> Checking the cache against ${TAG}..."
STALE_PACKAGES=(); FIRST_STALE=0
for i in {1..${#EXPECTED_PACKAGES[@]}}; do
  pkg="${EXPECTED_PACKAGES[$i]}"
  tgz="${PROVEN_DIR}/${pkg}.tar.gz"
  manifest="${tgz}.manifest.json"
  reason=""
  if [[ ! -f "${tgz}" ]]; then
    reason="absent from the cache"
  elif [[ ! -f "${manifest}" ]]; then
    reason="no provenance manifest"
  else
    m_pkg=$(command grep -oE '"package"[[:space:]]*:[[:space:]]*"[^"]*"' "${manifest}" | command sed -E 's/.*"([^"]*)"$/\1/')
    m_sha=$(command grep -oE '"source_sha256"[[:space:]]*:[[:space:]]*"[^"]*"' "${manifest}" | command sed -E 's/.*"([^"]*)"$/\1/')
    m_kind=$(command grep -oE '"kind"[[:space:]]*:[[:space:]]*"[^"]*"' "${manifest}" | command sed -E 's/.*"([^"]*)"$/\1/')
    if [[ "${m_kind}" != "proven_cache" ]]; then
      reason="not promoted by build-local.sh (kind=${m_kind:-<none>})"
    elif [[ "${m_pkg}" != "${pkg}" ]]; then
      reason="manifest names ${m_pkg}"
    elif [[ -n "${EXPECTED_SHAS[$i]}" && "${m_sha}" != "${EXPECTED_SHAS[$i]}" ]]; then
      reason="built from a different source tarball than ${TAG} declares"
    fi
  fi
  if [[ -n "${reason}" ]]; then
    echo "    STALE  ${pkg} — ${reason}"
    STALE_PACKAGES+=("${pkg}")
    if [[ ${FIRST_STALE} -eq 0 ]]; then
      FIRST_STALE=$i
    fi
  fi
done

if [[ ${FIRST_STALE} -eq 0 ]]; then
  echo "==> Cache matches ${TAG}. Nothing to rebuild."
  exit 0
fi

# Rebuild from the earliest drifted dependency onward, not just the ones whose
# own source changed. upstream's build_package compiles every dep with
# -I${TARGET}/include -L${TARGET}/lib and puts ${TARGET}/bin on PATH, so the
# contract it states is "anything built before me may be linked into me" — the
# sequence is the whole of it, and most deps name no dependency at all.
# Rebuilding ogg alone would leave the cached vorbis and flac linked against the
# ogg they replaced, with every hash still matching.
REBUILD_TARGETS=(); REBUILD_PACKAGES=()
for i in {${FIRST_STALE}..${#EXPECTED_PACKAGES[@]}}; do
  REBUILD_TARGETS+=("${EXPECTED_TARGETS[$i]}")
  REBUILD_PACKAGES+=("${EXPECTED_PACKAGES[$i]}")
done

echo ""
echo "==> ${#STALE_PACKAGES[@]} drifted; rebuilding ${#REBUILD_TARGETS[@]} of ${#EXPECTED_PACKAGES[@]},"
echo "    from ${EXPECTED_PACKAGES[$FIRST_STALE]} onward in upstream's own build order:"
echo "    ${REBUILD_TARGETS[*]}"

if [[ ${DRY_RUN} -eq 1 ]]; then
  echo "==> Dry run — nothing built."
  exit 0
fi

# --- Rebuild -----------------------------------------------------------------
# The workspace must hold the deps that are NOT being rebuilt, because upstream's
# build_<dep> functions link against what is already installed in the prefix.
echo ""
echo "==> Preparing the workspace..."
for item in "${TARGET}"/*; do
  case "${item:t}" in
    proven|proven-experimental|source) continue ;;
  esac
  command rm -rf "${item}"
done
mkdir -p "${TARGET}/include" "${TARGET}/lib" "${TARGET}/bin" "${TARGET}/packages"

echo "==> Restoring the cached dependencies built before ${EXPECTED_PACKAGES[$FIRST_STALE]}..."
for i in {1..${#EXPECTED_PACKAGES[@]}}; do
  pkg="${EXPECTED_PACKAGES[$i]}"
  if (( i >= FIRST_STALE )); then
    echo "    skip ${pkg} (being rebuilt)"
    continue
  fi
  (cd "${TARGET}" && tar xzf "${PROVEN_DIR}/${pkg}.tar.gz")
done
if [[ -f "${PROVEN_DIR}/docbook-xsl.tar.gz" ]]; then
  (cd "${TARGET}" && tar xzf "${PROVEN_DIR}/docbook-xsl.tar.gz")
fi

echo "==> Applying config overlay and patches..."
command cp "${SCRIPT_DIR}/config/config.local.sh" "${CLONE_DIR}/packaging/macos/config.local.sh"
for patch in "${SCRIPT_DIR}"/patches/*.patch; do
  [[ -f "${patch}" ]] || continue
  if git -C "${CLONE_DIR}" apply --check "${patch}" 2>/dev/null; then
    git -C "${CLONE_DIR}" apply "${patch}"
  elif ! git -C "${CLONE_DIR}" apply --reverse --check "${patch}" 2>/dev/null; then
    echo "ERROR: patch failed to apply: ${patch:t}" >&2
    exit 1
  fi
done
if [[ -d "${SCRIPT_DIR}/patches/qt-patches" ]]; then
  command cp -r "${SCRIPT_DIR}/patches/qt-patches" "${CLONE_DIR}/packaging/macos/qt-patches"
fi

echo ""
echo "==> Rebuilding: ${REBUILD_TARGETS[*]}"
(cd "${CLONE_DIR}/packaging/macos" && ./build.sh "${REBUILD_TARGETS[@]}")

# upstream builds cmark in an `mtx-build` directory and build_tarball names the
# archive after ${PWD:t}, so it lands as mtx-build.tar.gz rather than under
# cmark's versioned name. build-local.sh renames it after a full build; a
# partial rebuild that reaches cmark needs the same.
if [[ -f "${TARGET}/packages/mtx-build.tar.gz" ]]; then
  cmark_pkg="${REBUILD_PACKAGES[(r)cmark-*]}"
  if [[ -n "${cmark_pkg}" ]]; then
    echo "==> Renaming mtx-build.tar.gz to ${cmark_pkg}.tar.gz"
    command mv "${TARGET}/packages/mtx-build.tar.gz" "${TARGET}/packages/${cmark_pkg}.tar.gz"
  fi
fi

# --- Repromote just the rebuilt packages -------------------------------------
# Every package is checked before any is copied. The loop below writes into the
# cache as it goes, so exiting part-way would leave it half updated — a state
# that then validates clean, because each package it did write is self-consistent.
missing_built=()
for pkg in "${REBUILD_PACKAGES[@]}"; do
  [[ -f "${TARGET}/packages/${pkg}.tar.gz" ]] || missing_built+=("${pkg}")
done
if [[ ${#missing_built[@]} -gt 0 ]]; then
  echo "ERROR: the rebuild produced no package for:" >&2
  for pkg in "${missing_built[@]}"; do
    echo "    ${pkg}" >&2
  done
  echo "       The cache was NOT updated." >&2
  exit 1
fi

echo ""
echo "==> Repromoting ${#REBUILD_PACKAGES[@]} rebuilt package(s)..."
for pkg in "${REBUILD_PACKAGES[@]}"; do
  built="${TARGET}/packages/${pkg}.tar.gz"
  command cp "${built}" "${PROVEN_DIR}/${pkg}.tar.gz"
  (cd "${PROVEN_DIR}" && shasum -a 256 "${pkg}.tar.gz" > "${pkg}.tar.gz.sha256")
  _refresh_write_manifest "${pkg}" "${PROVEN_DIR}/${pkg}.tar.gz.manifest.json"
  echo "    promoted ${pkg} (+ .sha256, + .manifest.json)"
done

echo ""
echo "==> Done. The cache now matches ${TAG}."
echo "    Build with: ./build-local.sh ${TAG}"
echo "    The repo copy in proven/${ARCH_LABEL}/ is unchanged; run --promote"
echo "    after a verified build to archive these to LFS."
