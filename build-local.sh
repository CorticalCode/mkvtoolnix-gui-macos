#!/bin/zsh
# Guard: must be executed by zsh, not sourced or run by another shell
if [[ -z "${ZSH_VERSION}" ]]; then
  echo "ERROR: This script requires zsh. Run it with: ./build-local.sh" >&2
  exit 1
fi
if [[ "${ZSH_EVAL_CONTEXT}" == *:file ]]; then
  echo "ERROR: This script must be executed, not sourced." >&2
  return 1
fi

set -e
setopt NULL_GLOB  # Unmatched globs expand to nothing instead of aborting
unalias -a 2>/dev/null || true  # Prevent .zshenv aliases from leaking into script

# --- Startup tool probe ---
# Verify required external tools are reachable in PATH before doing real work.
# Without this, a missing tool surfaces mid-build with a cryptic pipe error;
# here it surfaces immediately with the tool's name. Same probe as
# tools/build-exp.sh — duplicated inline rather than sourced from a shared
# helper to keep each script self-contained.
#
# Note on `unalias -a` (line above): only affects THIS script's subshell.
# Your interactive aliases in the parent shell are unaffected.
_required_tools=(
  # POSIX core (every macOS install)
  awk grep sed find sort tr wc du xargs cat shasum file uname mktemp ls head
  # always present on macOS dev installs
  date rsync perl bc
  # macOS-specific (script is macOS-only by design; fail fast elsewhere)
  sw_vers sysctl xcrun clang hdiutil codesign strings otool
  # not shipped with macOS. The pre-flight checks upstream's release tag and
  # source tarball against mbunkus's key before any dependency is built, so this
  # is the host's gpg — not the gnupg the build later compiles for upstream's
  # own retrieve_verified_source_tarball. Undeclared, an absent gpg empties the
  # fingerprint comparison and the tarball check reports tampering.
  gpg
)
for _t in "${_required_tools[@]}"; do
  if ! command -v "$_t" >/dev/null 2>&1; then
    echo "ERROR: required tool '$_t' not found in PATH" >&2
    echo "       This script is for macOS builds. PATH=$PATH" >&2
    exit 1
  fi
done
unset _t _required_tools

TRAPZERR() {
  echo "ERROR: build-local.sh failed at ${funcfiletrace[1]:-line ${LINENO}} (exit code $?)" >&2
}

SCRIPT_DIR=${0:a:h}
UPSTREAM_URL="https://codeberg.org/mbunkus/mkvtoolnix.git"

# Detect architecture
MACHINE_ARCH=$(uname -m)
if [[ "${MACHINE_ARCH}" == "arm64" ]]; then
  ARCH_LABEL="arm"
elif [[ "${MACHINE_ARCH}" == "x86_64" ]]; then
  ARCH_LABEL="intel"
else
  ARCH_LABEL="${MACHINE_ARCH}"
fi
echo "==> Shell: zsh ${ZSH_VERSION}, arch: ${MACHINE_ARCH} (${ARCH_LABEL})"

function wipe_workspace {
  echo "==> Wiping workspace (preserving proven/, proven-experimental/, source/, and upstream clone)..."

  # Clean TARGET (~/opt/) — preserve proven cache, experimental cache, and source tarballs
  local preserve_proven="${TARGET}/proven"
  local preserve_experimental="${TARGET}/proven-experimental"
  local preserve_source="${TARGET}/source"

  for item in "${TARGET}"/*; do
    [[ "${item}" == "${preserve_proven}" ]] && continue
    [[ "${item}" == "${preserve_experimental}" ]] && continue
    [[ "${item}" == "${preserve_source}" ]] && continue
    echo "    Removing ${item:t}/"
    command rm -rf "${item}"
  done

  # Clean WORK_DIR (~/tmp/compile/) — preserve upstream clone and active log
  local preserve_clone="${WORK_DIR}/mkvtoolnix-src"

  for item in "${WORK_DIR}"/*; do
    [[ "${item}" == "${preserve_clone}" ]] && continue
    [[ "${item}" == "${LOG_FILE}" ]] && continue
    echo "    Removing ${item:t}"
    command rm -rf "${item}"
  done

  # Recreate essential directories
  mkdir -p "${TARGET}/include" "${TARGET}/lib" "${TARGET}/bin" "${TARGET}/packages"
  echo "==> Workspace clean."
}

function usage {
  cat <<'USAGE'
Usage: build-local.sh [options] [tag]

  tag               Upstream release tag (e.g. release-XX.0)
                    Required for build and promote. Not used by
                    --restore-cache or --cleanup-lfs.

Options:
  --full                 Force full rebuild from source (proven cache untouched)
  --promote              Archive proven to LFS, replace with current build
  --restore-cache        Pull proven deps from LFS to local cache and clean up
  --cleanup-lfs          Restore proven/ to pointer files and prune LFS cache
  --help                 Show this help

Default behavior:
  Wipes workspace, restores dependencies from proven cache,
  builds only what's missing + mkvtoolnix. If no proven cache
  exists, does a full build from source.

Environment:
  WORK_DIR          Compile workspace (default: ~/tmp/compile)
  TARGET            Install prefix (default: ~/opt)
USAGE
  exit 0
}

function is_lfs_pointer_file {
  local file="$1"

  [[ -f "${file}" ]] || return 1
  LC_ALL=C command dd if="${file}" bs=64 count=1 2>/dev/null | command grep -q "^version https://git-lfs\\.github\\.com/spec/v1$"
}

function verify_pkg_sha256 {
  # Fail closed three ways. A package with no sidecar is unverifiable, which is
  # not the same as verified; every writer into a cache directory emits one.
  # And `shasum -c` resolves the filename recorded *inside* the sidecar rather
  # than the path it was handed, so a sidecar naming a different package would
  # hash that one and report success for this one — hence the name is compared
  # before the hash is trusted, and the comparison is done here rather than
  # delegated to `-c`.
  # Prints a one-line reason, so a caller can collect every offender into one
  # report rather than stopping at the first.
  local pkg_file="$1"
  local sha_file="${pkg_file}.sha256"
  local record expected named actual
  local -a fields

  if [[ ! -f "${sha_file}" ]]; then
    print "no .sha256 sidecar"
    return 1
  fi

  record=$(head -1 "${sha_file}")
  fields=(${=record})   # deliberate split; shasum emits "<hash>  <filename>"
  expected="${fields[1]}"
  named="${fields[2]}"

  if [[ "${named}" != "${pkg_file:t}" ]]; then
    print "sidecar describes ${named:-<nothing>}, not ${pkg_file:t}"
    return 1
  fi

  actual=$(shasum -a 256 "${pkg_file}")
  actual="${actual%% *}"

  if [[ "${expected}" != "${actual}" ]]; then
    print "SHA256 mismatch (sidecar ${expected}, actual ${actual})"
    return 1
  fi
  return 0
}

# --- Manifest helpers ---
# Ported from tools/build-exp.sh, which has written provenance manifests for
# experimental builds since 2026-05-06. Duplicated rather than sourced: the two
# scripts stay self-contained by design, same as the tool probe above.

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

# Index of a package in the parallel spec arrays; returns 1 if absent.
_spec_index_for_package() {
  local want="$1" i
  [[ ${#EXPECTED_PACKAGES[@]} -eq 0 ]] && return 1
  for i in {1..${#EXPECTED_PACKAGES[@]}}; do
    if [[ "${EXPECTED_PACKAGES[$i]}" == "${want}" ]]; then
      print "$i"
      return 0
    fi
  done
  return 1
}

# Writes a provenance manifest beside a promoted package. The schema mirrors the
# dep_cache manifests tools/build-exp.sh writes so one reader handles both; what
# differs is the kind and the tool that produced it. dylib_count is deliberately
# not recorded — in the experimental writer it counts ${TARGET}/lib rather than
# the tarball, which is not what the field name suggests.
_write_proven_manifest() {
  local spec_name="$1" package="$2" tarball="$3" source_sha="$4" out="$5"
  local args_hash="" patch_hash wrapper_branch wrapper_sha
  # configure_args_hash exists for Qt only: build.sh has no comparable structured
  # args list for the other deps, and recording Qt's hash for zlib would misstate
  # zlib's identity. Empty means "no fingerprint", not "no drift".
  if [[ "${spec_name}" == "qt" && -f "${CLONE_DIR}/packaging/macos/build.sh" ]]; then
    args_hash=$(_qt_args_hash "${CLONE_DIR}/packaging/macos/build.sh")
  fi
  patch_hash=$(_patch_state_hash "${spec_name}")
  wrapper_branch=$(git -C "${SCRIPT_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  wrapper_sha=$(git -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  cat > "${out}" <<EOF
{
  "schema_version": 1,
  "kind": "proven_cache",
  "spec_name": $(_json_str "${spec_name}"),
  "package": $(_json_str "${package}"),
  "spec_tarball": $(_json_str "${tarball}"),
  "source_sha256": $(_json_str "${source_sha}"),
  "configure_args_hash": $(_json_str "${args_hash}"),
  "patch_state_hash": $(_json_str "${patch_hash}"),
  "built_at": $(_json_str "$(_iso_utc)"),
  "built_by": {
    "tool": "build-local.sh",
    "upstream_tag": $(_json_str "${TAG}"),
    "wrapper_branch": $(_json_str "${wrapper_branch}"),
    "wrapper_sha": $(_json_str "${wrapper_sha}")
  },
  "host": $(_host_json)
}
EOF
}

# Emit a manifest beside every package in a cache directory.
_write_cache_manifests() {
  local dir="$1" f pkg idx
  for f in "${dir}"/*.tar.gz(N); do
    pkg="${f:t:r:r}"
    # docbook-xsl is cached under an unversioned filename and carries no
    # spec-derived identity, so there is nothing for a manifest to bind to.
    [[ "${pkg}" == "docbook-xsl" ]] && continue
    if idx=$(_spec_index_for_package "${pkg}"); then
      _write_proven_manifest "${EXPECTED_TARGETS[$idx]}" "${pkg}" \
        "${EXPECTED_TARBALLS[$idx]}" "${EXPECTED_SHAS[$idx]}" "${f}.manifest.json"
    else
      echo "    WARNING: ${pkg} is not in this tag's spec set — no manifest written"
    fi
  done
}

# Validates a proven-cache manifest against the tag currently being built.
# Args:   $1=manifest path, $2=expected spec_name, $3=expected package,
#         $4=expected source sha256 (empty disables that check)
# Stdout: one-line human-readable result
# Exit:   0 valid · 1 refuse (critical mismatch) · 2 advisory drift
#
# source_sha256 is the load-bearing check: it is upstream's own declared hash,
# read from this tag's specs.sh, so it inherits the tag signature's trust root.
# configure_args_hash and patch_state_hash are advisory only — the first is
# source-level and blind to CXXFLAGS, deployment target, clang and SDK version,
# and exists for Qt alone. Neither is strong enough to refuse on.
_validate_proven_manifest() {
  local manifest="$1" exp_spec="$2" exp_pkg="$3" exp_src_sha="$4"
  local schema kind spec pkg src_sha

  if [[ ! -f "${manifest}" ]]; then
    print "no provenance manifest"
    return 1
  fi

  schema=$(_manifest_int_field "${manifest}" "schema_version")
  kind=$(_manifest_field "${manifest}" "kind")
  spec=$(_manifest_field "${manifest}" "spec_name")
  pkg=$(_manifest_field "${manifest}" "package")
  src_sha=$(_manifest_field "${manifest}" "source_sha256")

  if [[ -z "${schema}" ]]; then
    print "REFUSE: malformed manifest (no schema_version)"
    return 1
  fi
  if [[ "${schema}" != "1" ]]; then
    print "REFUSE: schema_version=${schema} (this build-local.sh handles only v1)"
    return 1
  fi
  if [[ "${kind}" != "proven_cache" ]]; then
    print "REFUSE: kind=${kind:-<none>} (expected proven_cache — not promoted by build-local.sh)"
    return 1
  fi
  if [[ "${spec}" != "${exp_spec}" ]]; then
    print "REFUSE: spec_name=${spec} (expected ${exp_spec})"
    return 1
  fi
  if [[ "${pkg}" != "${exp_pkg}" ]]; then
    print "REFUSE: package=${pkg} (expected ${exp_pkg})"
    return 1
  fi
  if [[ -n "${exp_src_sha}" && "${src_sha}" != "${exp_src_sha}" ]]; then
    print "REFUSE: built from a different source tarball than this tag declares"
    return 1
  fi

  local cur_args="" manifest_args cur_patch manifest_patch
  local -a drift=()
  if [[ "${exp_spec}" == "qt" && -f "${CLONE_DIR}/packaging/macos/build.sh" ]]; then
    cur_args=$(_qt_args_hash "${CLONE_DIR}/packaging/macos/build.sh")
  fi
  manifest_args=$(_manifest_field "${manifest}" "configure_args_hash")
  if [[ -n "${cur_args}" && -n "${manifest_args}" && "${cur_args}" != "${manifest_args}" ]]; then
    drift+=("configure_args:${manifest_args}→${cur_args}")
  fi
  cur_patch=$(_patch_state_hash "${exp_spec}")
  manifest_patch=$(_manifest_field "${manifest}" "patch_state_hash")
  if [[ -n "${cur_patch}" && -n "${manifest_patch}" && "${cur_patch}" != "${manifest_patch}" ]]; then
    drift+=("patch_state:${manifest_patch}→${cur_patch}")
  fi

  if [[ ${#drift[@]} -gt 0 ]]; then
    print "DRIFT: ${(j:, :)drift}"
    return 2
  fi
  print "ok"
  return 0
}

# Records every expected dep as built from source, for the build manifest. The
# restore path fills this array itself with per-package cache provenance.
_record_deps_from_source() {
  local pkg idx
  RESTORED_DEPS_JSON=()
  for pkg in "${EXPECTED_PACKAGES[@]}"; do
    idx=$(_spec_index_for_package "${pkg}") || continue
    RESTORED_DEPS_JSON+=("{\"package\":$(_json_str "${pkg}"),\"from\":\"built_from_source\",\"source_sha256\":$(_json_str "${EXPECTED_SHAS[$idx]}")}")
  done
  RESTORED_DEPS_JSON+=("{\"package\":\"docbook-xsl\",\"from\":\"built_from_source\",\"source_sha256\":\"\"}")
}

# Writes a provenance manifest beside the internal DMG in build/. Maintainer
# diagnostic, not a published artifact: its value is that diffing two manifests
# shows what changed between builds, where a substituted dependency would
# otherwise surface only as an unexplained size delta.
_write_build_manifest() {
  local out="$1" dmg_path="$2"
  local dmg_bytes dmg_sha app_bytes_m patches_json libs_json deps_json
  local wrapper_branch wrapper_sha src_tarball_sha

  dmg_bytes=$(command wc -c < "${dmg_path}" | command tr -d ' ')
  dmg_sha=$(shasum -a 256 "${dmg_path}" | command awk '{print $1}')
  app_bytes_m="${app_bytes:-0}"
  src_tarball_sha=""
  [[ -f "${TARBALL}" ]] && src_tarball_sha=$(shasum -a 256 "${TARBALL}" | command awk '{print $1}')
  wrapper_branch=$(git -C "${SCRIPT_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  wrapper_sha=$(git -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")

  local first=1 f
  patches_json="["
  for f in "${SCRIPT_DIR}"/patches/*.patch(N) "${SCRIPT_DIR}"/patches/qt-patches/*.patch(N); do
    [[ ${first} -eq 1 ]] && first=0 || patches_json+=", "
    patches_json+="{\"name\":$(_json_str "${f#${SCRIPT_DIR}/}"),\"sha256\":$(_json_str "$(shasum -a 256 "$f" | command awk '{print $1}')")}"
  done
  patches_json+="]"

  first=1
  libs_json="["
  for f in "${DMG_APP}/Contents/MacOS/libs"/*.dylib(N); do
    [[ -L "$f" ]] && continue
    [[ ${first} -eq 1 ]] && first=0 || libs_json+=", "
    libs_json+="$(_json_str "${f:t}")"
  done
  libs_json+="]"

  first=1
  deps_json="["
  for f in "${RESTORED_DEPS_JSON[@]}"; do
    [[ ${first} -eq 1 ]] && first=0 || deps_json+=", "
    deps_json+="${f}"
  done
  deps_json+="]"

  cat > "${out}" <<EOF
{
  "schema_version": 1,
  "kind": "release_build",
  "dmg": {
    "filename": $(_json_str "${dmg_path:t}"),
    "size_bytes": ${dmg_bytes},
    "sha256": $(_json_str "${dmg_sha}")
  },
  "app": {
    "size_bytes": ${app_bytes_m},
    "bundle_name": $(_json_str "${APP_BUNDLE_NAME:-unknown}"),
    "qt_version_in_binary": $(_json_str "${BUILT_QT_VERSION:-unknown}"),
    "bundled_libs": ${libs_json}
  },
  "build_meta": {
    "upstream_tag": $(_json_str "${TAG}"),
    "version": $(_json_str "${VERSION}"),
    "build_label": $(_json_str "${BUILD_LABEL:-unknown}"),
    "branch": $(_json_str "${BRANCH:-unknown}"),
    "mode": $(_json_str "${BUILD_MODE}"),
    "summary": $(_json_str "${BUILD_SUMMARY:-unknown}")
  },
  "source": {
    "wrapper_branch": $(_json_str "${wrapper_branch}"),
    "wrapper_sha": $(_json_str "${wrapper_sha}"),
    "tarball_sha256": $(_json_str "${src_tarball_sha}"),
    "qt_version_expected": $(_json_str "${QTVER:-unknown}")
  },
  "patches": ${patches_json},
  "deps": ${deps_json},
  "host": $(_host_json),
  "build_timing": {
    "started_at": $(_json_str "${BUILD_START_TIME}"),
    "finished_at": $(_json_str "$(_iso_utc)"),
    "duration_seconds": ${SECONDS}
  },
  "verification": {
    "passed": $(if [[ "${VERIFY_PASSED}" == true ]]; then print true; else print false; fi),
    "binaries_checked": ${arch_checked:-0},
    "arch_errors": ${arch_errors:-0},
    "app_size_mb": $(_json_str "${size_mb:-unknown}"),
    "leak_binaries_scanned": ${leak_scanned:-0}
  }
}
EOF

  # A manifest that does not parse is worse than none: it looks like provenance
  # and cannot be read. _json_str escapes five characters, and git subjects and
  # CPU brand strings are the realistic sources of anything else.
  if command -v python3 >/dev/null 2>&1; then
    if ! python3 -m json.tool "${out}" >/dev/null 2>&1; then
      echo "    WARNING: build manifest is not valid JSON — removing ${out:t}"
      command rm -f "${out}"
      return 1
    fi
  fi
  return 0
}

function cleanup_repo_lfs {
  local cleaned=false
  local -a arch_dirs=()
  local -a sample_file=()
  local arch_name arch_dir

  if [[ $# -gt 0 ]]; then
    for arch_name in "$@"; do
      arch_dirs+=("${SCRIPT_DIR}/proven/${arch_name}")
    done
  else
    arch_dirs=("${SCRIPT_DIR}"/proven/*(N/))
  fi

  for arch_dir in "${arch_dirs[@]}"; do
    [[ -d "${arch_dir}" ]] || continue
    arch_name="${arch_dir:t}"
    sample_file=("${arch_dir}"/*.tar.gz(N[1]))

    # Skip if no tar.gz files present
    [[ ${#sample_file[@]} -eq 0 ]] && continue

    if is_lfs_pointer_file "${sample_file[1]}"; then
      echo "    proven/${arch_name}/ already pointers."
      continue
    fi

    echo "    Restoring pointer files in proven/${arch_name}/..."
    # rm first: the clean filter normalizes the full binary to its committed
    # pointer, so a bare checkout sees no diff and is a no-op. Removing the
    # binaries forces checkout to repopulate them (as pointers, via SKIP_SMUDGE).
    (cd "${SCRIPT_DIR}" && command rm -f "proven/${arch_name}/"*.tar.gz(N) && GIT_LFS_SKIP_SMUDGE=1 git checkout -- "proven/${arch_name}/")

    # Verify the checkout actually restored pointers
    sample_file=("${arch_dir}"/*.tar.gz(N[1]))
    if [[ ${#sample_file[@]} -gt 0 ]] && ! is_lfs_pointer_file "${sample_file[1]}"; then
      echo "    WARNING: proven/${arch_name}/ files are still full binaries after checkout."
      echo "    This can happen on clones that predate .lfsconfig."
      echo "    To fix manually: rm proven/${arch_name}/*.tar.gz && GIT_LFS_SKIP_SMUDGE=1 git checkout -- proven/${arch_name}/"
    else
      cleaned=true
    fi
  done

  if [[ "${cleaned}" == true ]]; then
    echo "==> Pruning LFS object cache..."
    (cd "${SCRIPT_DIR}" && git lfs prune)
    echo "    Pruned LFS object cache."
  else
    echo "    No cleanup needed — all proven files are already pointers."
  fi
}

function run_cleanup_lfs_mode {
  echo "==> Cleaning up LFS objects..."
  cleanup_repo_lfs
  # This mode's whole purpose is reclaiming disk, so always prune. cleanup_repo_lfs
  # only prunes when it had to restore full binaries to pointers, which skips the
  # common post-promote+push case (files already pointers) — the exact case the
  # promote instructs this mode to handle. git lfs prune is safe (keeps unpushed +
  # recently-referenced objects) and arch-agnostic (each machine prunes its own cache).
  echo "==> Pruning LFS object cache..."
  (cd "${SCRIPT_DIR}" && git lfs prune)
  echo "==> Done. Repo proven/ restored to pointers; LFS cache pruned."
}

function run_restore_cache_mode {
  local repo_proven="${SCRIPT_DIR}/proven/${ARCH_LABEL}"
  local local_proven="${TARGET}/proven/${ARCH_LABEL}"
  local pull_status=0
  local -a pointer_files still_pointers
  local f

  echo "==> Restoring proven cache from LFS for ${ARCH_LABEL}..."

  # Check if proven files exist in repo
  pointer_files=("${repo_proven}"/*.tar.gz(N))
  if [[ ${#pointer_files[@]} -eq 0 ]]; then
    echo "ERROR: No proven files found in proven/${ARCH_LABEL}/"
    echo "  The repository may not have a proven cache for this architecture."
    return 1
  fi

  # Pull LFS objects for this arch only (override fetchexclude)
  echo "    Pulling LFS objects for ${ARCH_LABEL}..."
  if (cd "${SCRIPT_DIR}" && git lfs pull --include="proven/${ARCH_LABEL}/" --exclude=""); then
    :
  else
    pull_status=$?
    echo "ERROR: git lfs pull did not complete successfully."
    echo "  Restoring proven/${ARCH_LABEL}/ to pointer files to avoid a mixed LFS state."
    cleanup_repo_lfs "${ARCH_LABEL}"
    return ${pull_status}
  fi

  # Verify ALL files are real content (not still pointers)
  for f in "${pointer_files[@]}"; do
    if is_lfs_pointer_file "${f}"; then
      still_pointers+=("${f:t}")
    fi
  done
  if [[ ${#still_pointers[@]} -gt 0 ]]; then
    echo "ERROR: LFS pull did not download all files."
    echo "  ${#still_pointers[@]} files are still pointers:"
    echo "    ${still_pointers[*]}"
    echo "  Check your network connection and LFS access."
    echo "  Restoring proven/${ARCH_LABEL}/ to pointer files to avoid a mixed LFS state."
    cleanup_repo_lfs "${ARCH_LABEL}"
    return 1
  fi

  # Copy to local cache. The sidecars travel with the packages: they are the
  # hashes committed to the repo, so a package restored here is checkable
  # against signed history rather than against itself.
  # Check per package rather than by count: docbook-xsl legitimately has no
  # manifest (unversioned filename, no spec-derived identity), so a bare count
  # comparison would either reject a correct cache or accept an incomplete one.
  local -a incomplete=()
  local tgz stem
  for tgz in "${pointer_files[@]}"; do
    stem="${tgz:t:r:r}"
    [[ -f "${tgz}.sha256" ]] || incomplete+=("${stem}: no .sha256")
    if [[ "${stem}" != "docbook-xsl" ]] && [[ ! -f "${tgz}.manifest.json" ]]; then
      incomplete+=("${stem}: no .manifest.json")
    fi
  done
  if [[ ${#incomplete[@]} -gt 0 ]]; then
    echo "ERROR: proven/${ARCH_LABEL}/ is missing sidecars:"
    for stem in "${incomplete[@]}"; do
      echo "    ${stem}"
    done
    echo "  A package that cannot be verified or attributed will be refused at"
    echo "  restore time, so populating the cache from it would not help."
    return 1
  fi

  mkdir -p "${local_proven}"
  echo "    Copying ${#pointer_files[@]} packages + sidecars to ${local_proven}..."
  command cp "${repo_proven}"/*.tar.gz "${local_proven}/"
  command cp "${repo_proven}"/*.tar.gz.sha256 "${local_proven}/"
  local -a repo_manifests=("${repo_proven}"/*.tar.gz.manifest.json(N))
  [[ ${#repo_manifests[@]} -gt 0 ]] && command cp "${repo_manifests[@]}" "${local_proven}/"

  # Clean up repo working copy
  cleanup_repo_lfs "${ARCH_LABEL}"

  echo "==> Done. ${#pointer_files[@]} packages restored to ${local_proven}"
  echo "    Run './build-local.sh <tag>' to build using cached deps."
}

function validate_proven_cache {
  # Exit: 0 usable · 1 cache incomplete (caller may demote to a full build)
  #       2 cache contradicts the tag (caller must stop)
  #
  # Reads only, and runs before wipe_workspace: a refusal is a question for a
  # person, and handing them a wiped tree costs them the workspace they had.
  local proven_dir="${TARGET}/proven/${ARCH_LABEL}"
  local missing=()
  local pkg idx vmsg vrc
  local -a refused=() drifted=()

  echo "==> Validating proven cache against ${TAG}..."

  for pkg in "${EXPECTED_PACKAGES[@]}" docbook-xsl; do
    if [[ ! -f "${proven_dir}/${pkg}.tar.gz" ]]; then
      echo "    Missing: ${pkg}"
      missing+=("${pkg}")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "==> Proven cache incomplete: ${#missing[@]} package(s) missing."
    return 1
  fi

  # Every refusal is collected so one run names every offender rather than
  # stopping at the first. Identity is spec-derived, so docbook-xsl is out of
  # scope here: it is cached under an unversioned filename with nothing to
  # check against.
  for pkg in "${EXPECTED_PACKAGES[@]}"; do
    if ! idx=$(_spec_index_for_package "${pkg}"); then
      refused+=("${pkg}: not present in this tag's spec set")
      continue
    fi
    # A bare `vmsg=$(...)` would trip errexit on the validator's deliberate
    # non-zero returns, so capture the status through an if/else.
    if vmsg=$(_validate_proven_manifest "${proven_dir}/${pkg}.tar.gz.manifest.json" \
                "${EXPECTED_TARGETS[$idx]}" "${pkg}" "${EXPECTED_SHAS[$idx]}"); then
      vrc=0
    else
      vrc=$?
    fi
    case ${vrc} in
      1) refused+=("${pkg}: ${vmsg}") ;;
      2) drifted+=("${pkg}: ${vmsg}") ;;
    esac
  done

  # Hashes cover everything that gets extracted, docbook-xsl included. An
  # unverifiable package is refused rather than counted absent: a package that
  # is present but cannot be checked is a question about the cache, not a
  # reason to spend hours recompiling deps that are probably fine.
  for pkg in "${EXPECTED_PACKAGES[@]}" docbook-xsl; do
    if ! vmsg=$(verify_pkg_sha256 "${proven_dir}/${pkg}.tar.gz"); then
      refused+=("${pkg}: ${vmsg}")
    fi
  done

  if [[ ${#refused[@]} -gt 0 ]]; then
    echo ""
    echo "ERROR: the proven cache does not match ${TAG}."
    for pkg in "${refused[@]}"; do
      echo "    ${pkg}"
    done
    echo ""
    echo "  Nothing was extracted and the workspace is untouched."
    echo "  Repopulate packages and hashes from LFS:"
    echo "    ./build-local.sh --restore-cache"
    echo "  Rebuild just the affected dependencies:"
    echo "    ./tools/refresh-deps.sh ${TAG}"
    echo "  Or rebuild everything from source:"
    echo "    ./build-local.sh --full ${TAG}"
    # 2, not 1: an incomplete cache legitimately demotes to a full build, but a
    # cache that contradicts the tag is a decision for a human, not a fallback.
    return 2
  fi

  if [[ ${#drifted[@]} -gt 0 ]]; then
    echo "    Advisory drift (build continues; these fields are approximations):"
    for pkg in "${drifted[@]}"; do
      echo "      ${pkg}"
    done
  fi

  return 0
}

function restore_from_proven {
  # Extraction only; validate_proven_cache has already accepted this cache.
  # Release builds read the proven cache only. The experimental tier is owned by
  # tools/build-exp.sh, which both populates and consumes it; a release artifact
  # must be reproducible from what the repository ships in proven/.
  local proven_dir="${TARGET}/proven/${ARCH_LABEL}"
  local restored=0
  local pkg pkg_file idx

  echo "==> Restoring from proven cache..."

  for pkg in "${EXPECTED_PACKAGES[@]}" docbook-xsl; do
    pkg_file="${proven_dir}/${pkg}.tar.gz"
    echo "    Restoring ${pkg}..."
    (cd "${TARGET}" && tar xzf "${pkg_file}")
    restored=$((restored + 1))
    if [[ "${pkg}" == "docbook-xsl" ]]; then
      RESTORED_DEPS_JSON+=("{\"package\":$(_json_str "${pkg}"),\"from\":\"proven_cache\",\"source_sha256\":\"\"}")
    else
      idx=$(_spec_index_for_package "${pkg}")
      RESTORED_DEPS_JSON+=("{\"package\":$(_json_str "${pkg}"),\"from\":\"proven_cache\",\"source_sha256\":$(_json_str "${EXPECTED_SHAS[$idx]}")}")
    fi
  done

  echo "==> Restored ${restored} packages. Missing: 0."
}

function do_promote {
  local proven_dir="${TARGET}/proven/${ARCH_LABEL}"
  local packages_dir="${TARGET}/packages"
  local repo_proven="${SCRIPT_DIR}/proven/${ARCH_LABEL}"
  local missing_pkgs=()
  local pkg

  # Precondition: must be on main branch
  # Promote commits to proven/ — only main should accumulate those commits.
  local current_branch
  current_branch=$(cd "${SCRIPT_DIR}" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [[ "${current_branch}" != "main" ]]; then
    echo "ERROR: Promote refused — current branch is '${current_branch}', not 'main'."
    echo "       Promotion commits to the proven/ directory; this must only happen on main."
    echo "       Switch branches and try again: git switch main"
    exit 1
  fi

  # Precondition: verification must have passed
  if [[ "${VERIFY_PASSED}" != true ]]; then
    echo "ERROR: Cannot promote — post-build verification did not pass."
    echo "       Build and verify first, then promote."
    exit 1
  fi

  # Precondition: packages must contain all expected deps + docbook-xsl.
  # A smart-restore build only rebuilds mkvtoolnix, so packages/ is incomplete
  # by design. That is not a failure when the proven cache already holds every
  # package this tag expects — there is simply nothing new to archive.
  local -a absent_from_proven=()
  for pkg in "${EXPECTED_PACKAGES[@]}" docbook-xsl; do
    [[ -f "${packages_dir}/${pkg}.tar.gz" ]] || missing_pkgs+=("${pkg}")
    [[ -f "${proven_dir}/${pkg}.tar.gz" ]]   || absent_from_proven+=("${pkg}")
  done
  if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
    if [[ ${#absent_from_proven[@]} -eq 0 ]]; then
      echo "==> Nothing to promote — the proven cache already holds every package"
      echo "    this tag expects, and this build rebuilt only mkvtoolnix."
      echo "    Dependencies are unchanged; the cache stands as-is."
      return 0
    fi
    echo "ERROR: Cannot promote — packages/ is incomplete (${#missing_pkgs[@]} missing)."
    echo "  Missing from packages/: ${missing_pkgs[*]}"
    echo "  Missing from proven/:   ${absent_from_proven[*]}"
    echo "  A smart-restore build rebuilds only mkvtoolnix, and the proven cache"
    echo "  cannot cover the gap. Run a --full build first, then promote."
    exit 1
  fi

  echo "==> Promoting ${#EXPECTED_PACKAGES[@]} packages + docbook-xsl (${ARCH_LABEL})..."

  # Step 1: Archive current proven to LFS
  local proven_files=("${proven_dir}"/*.tar.gz)
  if [[ -d "${proven_dir}" ]] && [[ ${#proven_files[@]} -gt 0 ]]; then
    echo "    Archiving current ${ARCH_LABEL} proven to LFS..."
    mkdir -p "${repo_proven}"
    command cp "${proven_dir}"/*.tar.gz "${repo_proven}/"
    # Copy the outgoing manifests rather than regenerating them: a regenerated
    # manifest would stamp the current tag's specs onto packages built earlier,
    # which is provenance the script does not actually have.
    local -a old_manifests=("${proven_dir}"/*.tar.gz.manifest.json(N))
    [[ ${#old_manifests[@]} -gt 0 ]] && command cp "${old_manifests[@]}" "${repo_proven}/"
    (cd "${repo_proven}" && for f in *.tar.gz; do shasum -a 256 "$f" > "$f.sha256"; done)
    (cd "${SCRIPT_DIR}" && git add "proven/${ARCH_LABEL}/"*.tar.gz "proven/${ARCH_LABEL}/"*.sha256 && git diff --cached --quiet || git commit -m "archive: ${ARCH_LABEL} proven deps before promotion $(date +%Y-%m-%d)" -- "proven/${ARCH_LABEL}/")
  fi

  # Step 2: Build new proven set in temp directory
  local pkg_files=("${packages_dir}"/*.tar.gz)
  if [[ ${#pkg_files[@]} -eq 0 ]]; then
    echo "ERROR: No packages found in ${packages_dir} — cannot promote."
    exit 1
  fi
  local proven_new="${TARGET}/proven-${ARCH_LABEL}-new"
  mkdir -p "${proven_new}"
  command cp "${pkg_files[@]}" "${proven_new}/"
  # A sidecar per package, so restore_from_proven can verify this cache. Here
  # the hash is generated from the package beside it and catches corruption;
  # the copy committed to the repo in step 5 is what anchors it for anyone
  # restoring from LFS.
  (cd "${proven_new}" && for f in *.tar.gz; do shasum -a 256 "$f" > "$f.sha256"; done)
  _write_cache_manifests "${proven_new}"

  # Step 3: Atomic swap — clean up stale old dir first to prevent nesting
  command rm -rf "${TARGET}/proven-${ARCH_LABEL}-old"
  if [[ -d "${proven_dir}" ]]; then
    command mv "${proven_dir}" "${TARGET}/proven-${ARCH_LABEL}-old"
  fi
  mkdir -p "${TARGET}/proven"
  command mv "${proven_new}" "${proven_dir}"

  # Step 4: Cleanup old
  if [[ -d "${TARGET}/proven-${ARCH_LABEL}-old" ]]; then
    command rm -rf "${TARGET}/proven-${ARCH_LABEL}-old"
  fi

  # Step 5: Update LFS with new proven. Sync repo_proven to EXACTLY the promoted
  # set — prune any tracked package no longer present (e.g. a version-bumped
  # predecessor like an old Qt/zlib) so it doesn't linger as an orphan. Step 1
  # already committed the outgoing cache, so anything pruned here stays
  # recoverable from git history.
  mkdir -p "${repo_proven}"
  for existing in "${repo_proven}"/*.tar.gz; do
    if [[ ! -f "${proven_dir}/${existing:t}" ]]; then
      echo "    Pruning stale proven package: ${existing:t}"
      command rm -f "${existing}" "${existing}.sha256" "${existing}.manifest.json"
    fi
  done
  command cp "${proven_dir}"/*.tar.gz "${repo_proven}/"
  local -a new_manifests=("${proven_dir}"/*.tar.gz.manifest.json(N))
  [[ ${#new_manifests[@]} -gt 0 ]] && command cp "${new_manifests[@]}" "${repo_proven}/"
  (cd "${repo_proven}" && for f in *.tar.gz; do shasum -a 256 "$f" > "$f.sha256"; done)
  # git add -A so pruned packages are staged as deletions, not just the new adds.
  (cd "${SCRIPT_DIR}" && git add -A "proven/${ARCH_LABEL}/" && git diff --cached --quiet || git commit -m "promote: ${ARCH_LABEL} proven deps $(date +%Y-%m-%d)" -- "proven/${ARCH_LABEL}/")

  echo "==> Promotion complete. Proven cache updated."
  echo "    LFS archive committed. Push when ready."

  # Clean up only the arch we promoted; leave other working copies alone.
  cleanup_repo_lfs "${ARCH_LABEL}"

  echo "    After pushing, run './build-local.sh --cleanup-lfs' to reclaim cached"
  echo "    objects this promote retained (git-lfs keeps objects of unpushed commits)."
}

# Defaults
TAG=""
BUILD_MODE="auto"  # auto, full, promote
WORK_DIR=${WORK_DIR:-$HOME/tmp/compile}
TARGET=${TARGET:-$HOME/opt}
PACKAGE_DIR="${TARGET}/packages"
BUILD_DIR="${SCRIPT_DIR}/build"
RELEASE_DIR="${SCRIPT_DIR}/release"
VERIFY_PASSED=false
# Per-dependency provenance for the build manifest, filled by whichever path
# supplied the deps.
RESTORED_DEPS_JSON=()

# Parse arguments
while [[ -n $1 ]]; do
  case $1 in
    --full)                BUILD_MODE="full" ;;
    --promote)             BUILD_MODE="promote" ;;
    --restore-cache)       BUILD_MODE="restore-cache" ;;
    --cleanup-lfs)         BUILD_MODE="cleanup-lfs" ;;
    --help|-h)             usage ;;
    -*)           echo "Unknown option: $1"; usage ;;
    *)            TAG="$1" ;;
  esac
  shift
done

# Handle --cleanup-lfs early (no tag, clone, or specs needed)
if [[ "${BUILD_MODE}" == "cleanup-lfs" ]]; then
  run_cleanup_lfs_mode
  exit 0
fi

# Handle --restore-cache early (no tag, clone, or specs needed)
if [[ "${BUILD_MODE}" == "restore-cache" ]]; then
  run_restore_cache_mode
  exit $?
fi

if [[ -z "${TAG}" ]]; then
  echo "ERROR: No release tag given. Pass one explicitly, e.g. release-XX.0 (see --help)." >&2
  exit 1
fi
VERSION=${TAG#release-}

# Ensure required directories exist
mkdir -p "${TARGET}/include" "${TARGET}/lib" "${PACKAGE_DIR}" "${WORK_DIR}"

# Start logging — capture everything from here onward (including the build header)
LOG_FILE="${WORK_DIR}/build-${VERSION}-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee "${LOG_FILE}") 2>&1
BUILD_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
SECONDS=0

# Build report function (defined early so EXIT trap can use it on any failure)
function write_report {
  local report_file="${WORK_DIR}/build-report-${VERSION}.txt"
  {
    local elapsed=$SECONDS
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))
    echo "Build Report: MKVToolNix ${VERSION}"
    echo "Started: ${BUILD_START_TIME}"
    echo "Finished: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Elapsed: ${mins}m $(printf '%02d' ${secs})s"
    echo "Architecture: ${MACHINE_ARCH} (${ARCH_LABEL})"
    echo "Mode: ${BUILD_MODE}"
    echo "Build: ${BUILD_SUMMARY:-unknown}"
    echo ""
    echo "Verification: $(if [[ "${VERIFY_PASSED}" == true ]]; then echo "PASSED"; else echo "FAILED"; fi)"
    [[ -n "${BUILT_QT_VERSION}" ]] && echo "Qt version: ${BUILT_QT_VERSION} (expected ${QTVER})"
    [[ -n "${size_mb}" ]] && echo "App size: ${size_mb} MB"
    echo ""
    [[ -n "${DMG_RELEASE_NAME}" ]] && echo "Release: ${RELEASE_DIR}/${DMG_RELEASE_NAME}"
    [[ -n "${DMG_NAME}" ]] && echo "Internal: ${BUILD_DIR}/${DMG_NAME}"
    [[ -n "${LOG_NAME}" ]] && echo "Log: ${LOG_DIR}/${LOG_NAME}"
    echo "Build log: ${LOG_FILE}"
  } > "${report_file}"
  echo "==> Build report: ${report_file}"
}

# Write build report on exit (success or failure)
trap '{
  BUILD_SUMMARY="${BUILD_SUMMARY:-FAILED (script exited unexpectedly)}"
  write_report
  sleep 0.1  # allow tee to flush
}' EXIT
trap 'echo "==> Interrupted."; exit 130' INT TERM HUP

echo "==> Building MKVToolNix ${VERSION} for ${MACHINE_ARCH} (${ARCH_LABEL})"
echo "==> Mode: ${BUILD_MODE}"
echo "==> Work directory: ${WORK_DIR}"
echo "==> Logging to ${LOG_FILE}"

# Clone upstream at the specified tag (or verify existing clone matches)
CLONE_DIR="${WORK_DIR}/mkvtoolnix-src"
if [[ ! -d "${CLONE_DIR}/.git" ]]; then
  echo "==> Cloning upstream ${TAG}..."
  git clone --depth 1 --branch "${TAG}" "${UPSTREAM_URL}" "${CLONE_DIR}"
else
  # Verify the clone is on the correct tag
  CURRENT_TAG=$(git -C "${CLONE_DIR}" describe --tags --exact-match 2>/dev/null || true)
  if [[ "${CURRENT_TAG}" != "${TAG}" ]]; then
    echo "==> Clone exists but is on ${CURRENT_TAG:-unknown}, need ${TAG}. Re-cloning..."
    command rm -rf "${CLONE_DIR}"
    git clone --depth 1 --branch "${TAG}" "${UPSTREAM_URL}" "${CLONE_DIR}"
  else
    echo "==> Source already cloned at ${CLONE_DIR} (${TAG})"
  fi
fi

# Reset source tree for clean patch application
cd "${CLONE_DIR}"
git checkout -- .
git clean -fd -q  # Remove untracked files from prior runs (qt-patches, config overlay, etc.)

# Verify upstream tag signature against pinned mbunkus key.
# Roots specs.sh + all dependency hashes in mbunkus's key (without this,
# specs.sh integrity depends on codeberg integrity alone).
echo "==> Verifying upstream tag signature..."

if [[ ! -f "${SCRIPT_DIR}/tools/mbunkus-pubkey.asc" ]]; then
  echo "ERROR: mbunkus pubkey not found at expected location" >&2
  exit 1
fi

GPG_TAG_DIR=$(mktemp -d)
gpg --homedir "${GPG_TAG_DIR}" --batch --quiet \
  --import "${SCRIPT_DIR}/tools/mbunkus-pubkey.asc" 2>/dev/null

# Set GNUPGHOME directly — more reliable than git's gpg.programOptions
# across the macOS git versions we support.
verify_output=$(GNUPGHOME="${GPG_TAG_DIR}" \
  git -C "${CLONE_DIR}" verify-tag --raw "${TAG}" 2>&1 || true)

if ! echo "${verify_output}" | grep -q "GOODSIG"; then
  command rm -rf "${GPG_TAG_DIR}"
  echo "ERROR: Tag signature verification FAILED for ${TAG}" >&2
  echo "  The codeberg tag is not signed by the pinned mbunkus key." >&2
  echo "  Possible causes:" >&2
  echo "    - Codeberg compromise (highest concern)" >&2
  echo "    - Tag is unsigned (upstream policy change?)" >&2
  echo "    - Upstream rotated keys (run verify-mbunkus-key workflow)" >&2
  echo "" >&2
  echo "  --- gpg output ---" >&2
  echo "${verify_output}" | sed 's/^/  /' >&2
  exit 1
fi

expected_fp=$(tr -d '[:space:]' < "${SCRIPT_DIR}/tools/mbunkus-fingerprint.txt")
signing_fp=$(echo "${verify_output}" | awk '/VALIDSIG/ {print $12; exit}')
if [[ -n "${signing_fp}" ]] && [[ "${signing_fp}" != "${expected_fp}" ]]; then
  command rm -rf "${GPG_TAG_DIR}"
  echo "ERROR: Tag signed by unexpected key" >&2
  echo "  Expected: ${expected_fp}" >&2
  echo "  Got:      ${signing_fp}" >&2
  exit 1
fi

command rm -rf "${GPG_TAG_DIR}"
echo "==> Verified: tag ${TAG} signed by mbunkus key ${expected_fp}"

# Copy our config overlay (after clean, so it doesn't get removed)
echo "==> Applying config overlay..."
command cp "${SCRIPT_DIR}/config/config.local.sh" "${CLONE_DIR}/packaging/macos/config.local.sh"

# Apply patches
echo "==> Applying patches..."
for patch in "${SCRIPT_DIR}"/patches/*.patch; do
  [[ -f "${patch}" ]] || continue
  echo "    Applying ${patch:t}..."
  if git apply --check "${patch}" 2>/dev/null; then
    git apply "${patch}"
  elif git apply --reverse --check "${patch}" 2>/dev/null; then
    echo "    (already applied)"
  else
    echo "ERROR: Patch failed to apply: ${patch:t}"
    echo "  Not applicable forward or in reverse — may be outdated or broken"
    exit 1
  fi
done

# Copy Qt source patches (applied by upstream build.sh via qt-patches/ mechanism)
if [[ -d "${SCRIPT_DIR}/patches/qt-patches" ]]; then
  echo "==> Installing Qt source patches..."
  command cp -r "${SCRIPT_DIR}/patches/qt-patches" "${CLONE_DIR}/packaging/macos/qt-patches"
fi

# --- Pre-build verification ---

# Source the config files the same way build.sh does, to get QTVER
# Save our state — sourced files can disable set -e, change options, clobber vars
_SAVED_TARGET="${TARGET}"
_SAVED_WORK_DIR="${WORK_DIR}"
_SAVED_OPTS=$(setopt | tr '\n' ' ')
source "${CLONE_DIR}/packaging/macos/config.sh"
test -f "${CLONE_DIR}/packaging/macos/config.local.sh" && source "${CLONE_DIR}/packaging/macos/config.local.sh"
source "${CLONE_DIR}/packaging/macos/specs.sh"
# Restore our state — re-enable options that sourced files may have disabled
setopt ${=_SAVED_OPTS} 2>/dev/null
set -e
TARGET="${_SAVED_TARGET}"
WORK_DIR="${_SAVED_WORK_DIR}"
echo "==> Config: TARGET=${TARGET}, WORK_DIR=${WORK_DIR}"

# Derive QTVER from specs.sh — the single source of truth for dependency
# versions — instead of a manual pin in config.local.sh. This is authoritative
# over any QTVER from the config files, so a stale pin can no longer cause a
# wrong-Qt build and there's no per-release QTVER edit. Exported so the upstream
# build.sh (which reads QTVER=${QTVER:-...}) picks up the same value.
SPECS_QT_FILE="${spec_qt[1]}"
QTVER="${SPECS_QT_FILE#qt-everywhere-src-}"
QTVER="${QTVER%.tar.*}"
export QTVER
if [[ -z "${QTVER}" || "${SPECS_QT_FILE}" != "qt-everywhere-src-${QTVER}.tar."* ]]; then
  echo "ERROR: could not derive the Qt version from specs.sh (spec_qt='${SPECS_QT_FILE}')." >&2
  echo "       Upstream may have changed the Qt spec naming; check packaging/macos/specs.sh." >&2
  exit 1
fi
echo "==> Qt version (derived from specs.sh): ${QTVER} (${SPECS_QT_FILE})"

# Verify upstream mkvtoolnix tarball signature before letting build.sh use it.
# Upstream build.sh does not checksum or signature-verify the source tarball
# (build_package /path mode bypasses retrieve_file).
PUBKEY="${SCRIPT_DIR}/tools/mbunkus-pubkey.asc"
PINNED_FP_FILE="${SCRIPT_DIR}/tools/mbunkus-fingerprint.txt"
SOURCE_DIR="${SRCDIR:-${HOME}/opt/source}"
TARBALL="${SOURCE_DIR}/mkvtoolnix-${VERSION}.tar.xz"
SIGFILE="${TARBALL}.sig"
TARBALL_URL="https://mkvtoolnix.download/sources/mkvtoolnix-${VERSION}.tar.xz"

if [[ ! -f "${PUBKEY}" ]] || [[ ! -f "${PINNED_FP_FILE}" ]]; then
  echo "ERROR: missing GPG trust artifacts in tools/. See tools/README.md."
  exit 1
fi

PINNED_FP=$(tr -d '[:space:]' < "${PINNED_FP_FILE}")
EMBEDDED_FP=$(gpg --show-keys --with-colons --with-fingerprint "${PUBKEY}" 2>/dev/null \
  | awk -F: '$1=="fpr" {print $10; exit}')
if [[ "${EMBEDDED_FP}" != "${PINNED_FP}" ]]; then
  echo "ERROR: embedded mbunkus key fingerprint does not match pinned text file."
  echo "  embedded (${PUBKEY}): ${EMBEDDED_FP}"
  echo "  pinned   (${PINNED_FP_FILE}): ${PINNED_FP}"
  echo "  One of those was tampered with — refuse to build."
  exit 1
fi

mkdir -p "${SOURCE_DIR}"

if [[ ! -f "${TARBALL}" ]]; then
  echo "==> Downloading mkvtoolnix-${VERSION}.tar.xz..."
  curl -fsSL "${TARBALL_URL}" -o "${TARBALL}"
fi

if [[ ! -f "${SIGFILE}" ]]; then
  echo "==> Downloading mkvtoolnix-${VERSION}.tar.xz.sig..."
  curl -fsSL "${TARBALL_URL}.sig" -o "${SIGFILE}"
fi

GPG_TEMP_DIR=$(mktemp -d)
gpg --homedir "${GPG_TEMP_DIR}" --batch --quiet --import "${PUBKEY}" 2>/dev/null
if ! gpg --homedir "${GPG_TEMP_DIR}" --batch --quiet --verify "${SIGFILE}" "${TARBALL}" 2>/dev/null; then
  command rm -rf "${GPG_TEMP_DIR}"
  echo "ERROR: GPG signature verification FAILED for ${TARBALL}"
  echo "  Either the tarball is modified/corrupted, the .sig is stale, or"
  echo "  upstream rotated the signing subkey (run the verify-mbunkus-key"
  echo "  GitHub Action / refresh tools/mbunkus-pubkey.asc per tools/README.md)."
  echo "  To force re-download: rm '${TARBALL}' '${SIGFILE}' && rerun this script"
  exit 1
fi
command rm -rf "${GPG_TEMP_DIR}"
echo "==> Verified: tarball signature OK (mbunkus key ${PINNED_FP:0:16}...)"

# Derive expected package names from specs.sh (single source of truth for versions)
# Produces names like: autoconf-2.69, boost_1_88_0, qt-everywhere-src-6.10.2, etc.
# spec_gpg (gnupg) is built from source and cached: upstream's
# retrieve_verified_source_tarball uses gpg to check the mkvtoolnix source
# signature, so smart-restore builds need it in the proven cache.
EXPECTED_SPEC_VARS=(
  spec_autoconf spec_automake spec_pkgconfig spec_libiconv
  spec_cmake spec_ogg spec_vorbis spec_flac spec_zlib spec_gettext
  spec_cmark spec_gmp spec_boost spec_qt spec_gpg
)
# Four index-parallel arrays. EXPECTED_SPEC_VARS is declared in upstream's own
# build order (see build.sh's no-argument sequence), which is what lets a
# partial rebuild pass a filtered target list without modelling dependencies.
#   PACKAGES  cache filename stem        TARGETS   build.sh's build_<name>
#   TARBALLS  upstream source filename   SHAS      upstream's declared source hash
EXPECTED_PACKAGES=()
EXPECTED_TARGETS=()
EXPECTED_TARBALLS=()
EXPECTED_SHAS=()
for spec_var in "${EXPECTED_SPEC_VARS[@]}"; do
  filename="${${(P)spec_var}[1]}"
  if [[ -z "${filename}" ]]; then
    echo "ERROR: ${spec_var} not found in specs.sh — upstream may have renamed it"
    echo "  Check the upstream specs.sh and update EXPECTED_SPEC_VARS"
    exit 1
  fi
  pkg="${filename%%.tar.*}"
  EXPECTED_PACKAGES+=("${pkg}")
  EXPECTED_TARGETS+=("${spec_var#spec_}")
  EXPECTED_TARBALLS+=("${filename}")
  # spec arrays are (filename url sha256); index 3 is empty if upstream omits it,
  # which disables the source-hash check for that dep rather than failing it.
  EXPECTED_SHAS+=("${${(P)spec_var}[3]:-}")
done
# Fix zlib naming (spec has zlib-v1.3.1, package is zlib-1.3.1)
EXPECTED_PACKAGES=("${EXPECTED_PACKAGES[@]/zlib-v/zlib-}")

# Clean stale build directories — derive glob prefixes from EXPECTED_PACKAGES
echo "==> Cleaning stale build directories..."
for pkg in "${EXPECTED_PACKAGES[@]}"; do
  # Extract the name prefix before the version (e.g., "autoconf" from "autoconf-2.69")
  pkg_prefix="${pkg%%-[0-9]*}"
  [[ "${pkg_prefix}" == "${pkg}" ]] && pkg_prefix="${pkg%%_[0-9]*}"  # handle boost_1_88_0
  for stale_dir in "${WORK_DIR}/${pkg_prefix}"*; do
    if [[ -d "${stale_dir}" ]] && [[ "${stale_dir:t}" != "${pkg}" ]]; then
      echo "    Removing stale: ${stale_dir:t}"
      command rm -rf "${stale_dir}"
    fi
  done
done

# --- Build ---

cd "${CLONE_DIR}/packaging/macos"

case "${BUILD_MODE}" in
  full)
    echo "==> Full build (all dependencies + mkvtoolnix from source)..."
    BUILD_SUMMARY="Full build from source"
    wipe_workspace
    _record_deps_from_source
    ./build.sh
    ;;
  promote)
    local promote_pkgs=("${TARGET}/packages"/*.tar.gz)
    if [[ ! -d "${TARGET}/packages" ]] || [[ ${#promote_pkgs[@]} -eq 0 ]]; then
      echo "ERROR: No build packages found. Build first, then promote."
      exit 1
    fi
    BUILD_SUMMARY="Promote (verification only)"
    echo "==> Promote mode — skipping build, running verification..."
    ;;
  auto|"")
    if validate_proven_cache; then
      cache_rc=0
    else
      cache_rc=$?
    fi
    if [[ ${cache_rc} -eq 2 ]]; then
      # Refusal, not absence. Demoting to a full build here would paper over a
      # cache that disagrees with the tag; the message above says what to run.
      # Nothing has been wiped yet, so the existing workspace survives.
      exit 1
    fi
    wipe_workspace
    if [[ ${cache_rc} -eq 0 ]]; then
      restore_from_proven
      BUILD_SUMMARY="Restored from proven, built mkvtoolnix only"
      echo "==> All dependencies restored from proven. Building mkvtoolnix only..."
      # shared-mime-info produces no cacheable package (NO_CONFIGURE installs the
      # MIME DB straight into ${TARGET}/share/mime), so restore can't bring it back.
      # Rebuild it before mkvtoolnix, or build_configured_mkvtoolnix silently ships
      # without the FreeDesktop MIME DB (upstream #6248).
      ./build.sh shared_mime_info
      ./build.sh mkvtoolnix
    else
      BUILD_SUMMARY="No proven cache, full build from source"
      echo "==> Some dependencies missing from proven. Doing full build..."
      echo "    Hint: run './build-local.sh --restore-cache' to pull updated deps from LFS."
      _record_deps_from_source
      ./build.sh
    fi
    ;;
esac

# Post-build fixups and DMG (skip for promote mode — packages already exist)
if [[ "${BUILD_MODE}" != "promote" ]]; then
  # Rename unversioned cmark package to include version
  if [[ -f "${TARGET}/packages/mtx-build.tar.gz" ]]; then
    cmark_version=$(echo "${EXPECTED_PACKAGES[@]}" | tr ' ' '\n' | grep "^cmark-" || true)
    if [[ -n "${cmark_version}" ]]; then
      echo "==> Renaming mtx-build.tar.gz to ${cmark_version}.tar.gz"
      command mv "${TARGET}/packages/mtx-build.tar.gz" "${TARGET}/packages/${cmark_version}.tar.gz"
    fi
  fi

  # Archive docbook-xsl if not already in packages
  if [[ -d "${TARGET}/xsl-stylesheets" ]] && [[ ! -f "${TARGET}/packages/docbook-xsl.tar.gz" ]]; then
    local docbook_dirs=("${TARGET}"/docbook-xsl-*)
    if [[ ${#docbook_dirs[@]} -gt 0 ]]; then
      echo "==> Archiving docbook-xsl..."
      (cd "${TARGET}" && tar czf "${TARGET}/packages/docbook-xsl.tar.gz" xsl-stylesheets "${docbook_dirs[@]:t}")
    else
      echo "WARNING: xsl-stylesheets exists but no docbook-xsl-* directories found — archive may be incomplete"
      (cd "${TARGET}" && tar czf "${TARGET}/packages/docbook-xsl.tar.gz" xsl-stylesheets)
    fi
  fi

  # Package DMG
  echo "==> Building DMG..."
  ./build.sh dmg

  # Re-derive VERSION from the actual DMG filename upstream produced.
  # VERSION is initially derived as ${TAG#release-}, which is correct only when
  # TAG is a release-X.Y tag. For branch-name tags (e.g. "main") the DMG is
  # named after the in-source AC_INIT version string (e.g. "98.0" or
  # "99.0-pre.1" with the version-marker patch), not after the TAG.
  #
  # release-99.0 changed the DMG name to
  # MKVToolNix-${MTX_VER}-${DMG_REVISION}-${machine}.dmg, so strip the known
  # ${DMG_REVISION} and machine suffixes to recover the clean upstream version.
  # ${DMG_REVISION} comes from upstream config.sh, sourced during pre-build.
  # -maxdepth 1 -type f excludes the `latest` symlink upstream creates.
  ACTUAL_DMG=$(command find "${WORK_DIR}" -maxdepth 1 -type f -name 'MKVToolNix-*.dmg' -print 2>/dev/null | command head -1)
  if [[ -n "${ACTUAL_DMG}" ]]; then
    _dmg_machine=$(command uname -m)
    ACTUAL_VERSION=$(basename "${ACTUAL_DMG}" .dmg)
    ACTUAL_VERSION=${ACTUAL_VERSION#MKVToolNix-}
    ACTUAL_VERSION=${ACTUAL_VERSION%-${_dmg_machine}}
    ACTUAL_VERSION=${ACTUAL_VERSION%-${DMG_REVISION}}
    if [[ "${ACTUAL_VERSION}" != "${VERSION}" ]]; then
      echo "==> VERSION corrected from '${VERSION}' (from TAG) to '${ACTUAL_VERSION}' (from DMG filename)"
      VERSION="${ACTUAL_VERSION}"
    fi
  else
    echo "WARNING: upstream build.sh completed but no DMG found in ${WORK_DIR}. Downstream verification and copy steps will likely fail."
  fi
fi

# --- Post-build verification ---

VERIFY_PASSED=true
# Upstream stages the app at dmg-${MTX_VER}/${APP_BUNDLE_NAME}; release-99.0
# renamed the bundle to a fixed "MKVToolNix.app" (APP_BUNDLE_NAME from config.sh)
# rather than the old MKVToolNix-${VERSION}.app.
DMG_APP="${WORK_DIR}/dmg-${VERSION}/${APP_BUNDLE_NAME}"

if [[ -d "${DMG_APP}" ]]; then
  echo "==> Running post-build verification..."

  # 1. Qt version in binary
  BUILT_QT_VERSION=$(otool -L "${DMG_APP}/Contents/MacOS/mkvtoolnix-gui" 2>/dev/null | grep libQt6Core | sed 's/.*current version \([0-9.]*\).*/\1/' || true)
  if [[ -n "${BUILT_QT_VERSION}" ]]; then
    if [[ "${BUILT_QT_VERSION}" == "${QTVER}" ]]; then
      echo "    PASS: Qt version ${BUILT_QT_VERSION} matches expected ${QTVER}"
    else
      echo "    FAIL: Qt version mismatch — binary has ${BUILT_QT_VERSION}, expected ${QTVER}"
      VERIFY_PASSED=false
    fi
  else
    echo "    FAIL: Could not determine Qt version from binary"
    VERIFY_PASSED=false
  fi

  # 2. Architecture check on ALL binaries and dylibs
  arch_errors=0
  arch_checked=0
  expected_arch="${MACHINE_ARCH}"
  if [[ -d "${DMG_APP}/Contents/MacOS" ]]; then
    while IFS= read -r -d '' binary; do
      file_info=$(file "${binary}" 2>/dev/null || true)
      # Skip non-Mach-O files (scripts, text, etc.)
      [[ "${file_info}" == *"Mach-O"* ]] || continue
      arch_checked=$((arch_checked + 1))
      if [[ "${file_info}" != *"${expected_arch}"* ]]; then
        echo "    FAIL: Wrong architecture in ${binary:t} (expected ${expected_arch})"
        arch_errors=$((arch_errors + 1))
        VERIFY_PASSED=false
      fi
    # -type f selects every regular file, excluding directories and the version
    # symlinks that alias each dylib; the Mach-O test above is what narrows it
    # to actual binaries. Nothing here depends on a permission bit, so a file
    # that is Mach-O without the execute bit is still checked.
    done < <(command find "${DMG_APP}/Contents/MacOS" -type f -print0 2>/dev/null)
  fi
  if [[ ${arch_checked} -eq 0 ]]; then
    echo "    FAIL: No binaries found to check architecture"
    VERIFY_PASSED=false
  elif [[ ${arch_errors} -eq 0 ]]; then
    echo "    PASS: All ${arch_checked} binaries and dylibs are ${expected_arch}"
  fi

  # 3. Duplicate dylib scan
  dupes=$(command find "${DMG_APP}/Contents/MacOS/libs" -name "*.dylib" -not -type l 2>/dev/null | sed 's/\(\.[0-9][0-9]*\)*\.dylib/.dylib/' | sort | uniq -d)
  if [[ -n "${dupes}" ]]; then
    echo "    FAIL: Duplicate dylib versions found:"
    echo "${dupes}" | while read -r d; do echo "      ${d}"; done
    VERIFY_PASSED=false
  else
    echo "    PASS: No duplicate dylib versions"
  fi

  # 4. Size sanity check (decimal MB to match Finder)
  # Summing the bytes by reading them avoids asking stat for a size, which is
  # spelled differently on BSD and GNU. Concatenating into wc also sidesteps
  # parsing filenames out of per-file output.
  app_bytes=$(command find "${DMG_APP}" -type f -exec cat {} + 2>/dev/null | command wc -c | command tr -d ' ')
  size_mb=$(echo "${app_bytes}" | awk '{printf "%.1f", $1/1000/1000}')
  min_size=60  # MB — below this something is missing
  max_size=95  # MB — above this something is duplicated
  if (( $(echo "${size_mb} < ${min_size}" | bc -l) )); then
    echo "    FAIL: App is ${size_mb} MB — suspiciously small (expected ${min_size}-${max_size} MB)"
    VERIFY_PASSED=false
  elif (( $(echo "${size_mb} > ${max_size}" | bc -l) )); then
    echo "    FAIL: App is ${size_mb} MB — suspiciously large (expected ${min_size}-${max_size} MB)"
    VERIFY_PASSED=false
  else
    echo "    PASS: App size ${size_mb} MB (expected range ${min_size}-${max_size} MB)"
  fi

  # 5. Homebrew / external library leak detection
  #
  # This is the check that caught the v98 DYLD crash, so it must never report a
  # clean result without having looked. Two ways that could happen, both closed
  # here: an empty dylib list (NULL_GLOB makes an unmatched glob vanish) and an
  # otool that produces no output. Either means "not scanned", not "clean".
  leak_found=false
  leak_scanned=0
  local -a leak_targets=("${DMG_APP}/Contents/MacOS/libs/"*.dylib(N) "${DMG_APP}/Contents/MacOS/mkvtoolnix-gui")
  for lib in "${leak_targets[@]}"; do
    [[ -e "$lib" ]] || continue
    otool_out=$(otool -L "$lib" 2>/dev/null || true)
    if [[ -z "${otool_out}" ]]; then
      echo "    FAIL: otool produced no output for $(basename $lib) — cannot verify linkage"
      VERIFY_PASSED=false
      continue
    fi
    leak_scanned=$((leak_scanned + 1))
    leaks=$(print -r -- "${otool_out}" | grep -E "/opt/homebrew|/usr/local/opt" || true)
    if [[ -n "$leaks" ]]; then
      echo "    FAIL: External library reference in $(basename $lib):"
      echo "$leaks" | while read -r line; do echo "      $line"; done
      leak_found=true
      VERIFY_PASSED=false
    fi
  done
  if [[ ${leak_scanned} -lt 2 ]]; then
    echo "    FAIL: Only ${leak_scanned} binaries scanned for external references"
    echo "          (expected the bundled dylibs plus mkvtoolnix-gui)"
    VERIFY_PASSED=false
  elif [[ "$leak_found" == false ]]; then
    echo "    PASS: No Homebrew/external library references (${leak_scanned} binaries scanned)"
  fi

  # 6. Bundle inventory
  echo "    --- Bundle inventory ---"
  command find "${DMG_APP}/Contents/MacOS/libs" -name "*.dylib" -not -type l 2>/dev/null | while read -r lib; do
    echo "    $(basename "${lib}")"
  done

  # Summary
  if [[ "${VERIFY_PASSED}" == true ]]; then
    echo "==> Verification: ALL CHECKS PASSED"
  else
    echo "==> Verification: SOME CHECKS FAILED — review output above"
  fi
else
  if [[ "${BUILD_MODE}" == "promote" ]]; then
    echo "ERROR: App bundle not found at ${DMG_APP}"
    echo "  The DMG from the previous build may have been cleaned. Build again first."
  else
    echo "==> WARNING: App bundle not found at ${DMG_APP} — skipping verification"
  fi
  VERIFY_PASSED=false
fi

# Handle promotion after verification
if [[ "${BUILD_MODE}" == "promote" ]]; then
  do_promote
  exit 0
fi

# --- Name and copy DMG ---

BUILD_COUNTER_FILE="${SCRIPT_DIR}/.build-counter-${ARCH_LABEL}-rel"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${BUILD_DIR}" "${RELEASE_DIR}" "${LOG_DIR}"

# Upstream's DMG carries ${DMG_REVISION}+machine suffixes (release-99.0), so use
# the actual file located after the build rather than reconstructing the name.
DMG_PATH="${ACTUAL_DMG:-${WORK_DIR}/MKVToolNix-${VERSION}.dmg}"

if [[ -f "${DMG_PATH}" ]]; then
  # Increment global build counter (atomic write via temp+mv)
  if [[ -f "${BUILD_COUNTER_FILE}" ]]; then
    BUILD_NUM=$(( $(cat "${BUILD_COUNTER_FILE}") + 1 ))
  else
    BUILD_NUM=1
  fi
  echo "${BUILD_NUM}" > "${BUILD_COUNTER_FILE}.tmp" && command mv "${BUILD_COUNTER_FILE}.tmp" "${BUILD_COUNTER_FILE}"

  # Get current git branch name for the label (sanitize slashes for filename)
  BRANCH=$(cd "${SCRIPT_DIR}" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  [[ "${BRANCH}" == "HEAD" ]] && BRANCH=$(cd "${SCRIPT_DIR}" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
  BRANCH="${BRANCH//\//-}"

  BUILD_LABEL="rel$(printf '%03d' ${BUILD_NUM})"
  DMG_NAME="MKVToolNix-${VERSION}-${ARCH_LABEL}-${BUILD_LABEL}-${BRANCH}.dmg"
  DMG_RELEASE_NAME="MKVToolNix-${VERSION}-macos-${ARCH_LABEL}.dmg"
  LOG_NAME="MKVToolNix-${VERSION}-${ARCH_LABEL}-${BUILD_LABEL}-${BRANCH}.log"
  command cp "${DMG_PATH}" "${BUILD_DIR}/${DMG_NAME}"
  command cp "${LOG_FILE}" "${LOG_DIR}/${LOG_NAME}"
  (cd "${BUILD_DIR}" && shasum -a 256 "${DMG_NAME}" > "${DMG_NAME}.sha256")
  if _write_build_manifest "${BUILD_DIR}/${DMG_NAME}.manifest.json" "${BUILD_DIR}/${DMG_NAME}"; then
    MANIFEST_WRITTEN="${BUILD_DIR}/${DMG_NAME}.manifest.json"
  fi

  # Release-ready DMG (no branch suffix). Two conditions gate it, because this
  # is the only artifact whose name implies it is fit to publish:
  #   - main only: another branch would produce a file that looks releasable
  #     and isn't.
  #   - verification passed: a bundle that failed the arch, size, dupe or leak
  #     checks must not acquire a release name. The internal build/ copy is
  #     still written so the failure can be examined.
  release_emitted=false
  if [[ "${BRANCH}" == "main" ]] && [[ "${VERIFY_PASSED}" == true ]]; then
    command cp "${DMG_PATH}" "${RELEASE_DIR}/${DMG_RELEASE_NAME}"
    (cd "${RELEASE_DIR}" && shasum -a 256 "${DMG_RELEASE_NAME}" > "${DMG_RELEASE_NAME}.sha256")
    release_emitted=true
  fi

  echo "==> Done!"
  echo "    Build output: ${DMG_PATH}"
  echo "    Internal: ${BUILD_DIR}/${DMG_NAME}"
  echo "    SHA256:   ${BUILD_DIR}/${DMG_NAME}.sha256"
  [[ -n "${MANIFEST_WRITTEN}" ]] && echo "    Manifest: ${MANIFEST_WRITTEN}"
  if [[ "${release_emitted}" == true ]]; then
    echo "    Release:  ${RELEASE_DIR}/${DMG_RELEASE_NAME}"
    echo "    SHA256:   ${RELEASE_DIR}/${DMG_RELEASE_NAME}.sha256"
  elif [[ "${BRANCH}" != "main" ]]; then
    echo "    Release:  (skipped — not on main)"
  else
    echo "    Release:  (WITHHELD — post-build verification did not pass)"
    echo "              Review the FAIL lines above. The internal copy above is"
    echo "              kept for diagnosis; it must not be published."
  fi
  echo "    Log:      ${LOG_DIR}/${LOG_NAME}"
else
  echo "==> DMG not found at expected path. Check ${WORK_DIR} for output."
  command ls -la "${WORK_DIR}"/MKVToolNix*.dmg 2>/dev/null || true
fi
