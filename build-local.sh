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
# The script uses BSD-specific `find -perm +111` syntax (line ~872 — see
# explicit BSD-vs-GNU comment there). GNU find errors out on that flag form.
# If a user has homebrew gfind first on PATH and it shadows BSD find, this
# catches it at startup.
if ! command find /tmp -maxdepth 0 -perm +111 >/dev/null 2>&1; then
  echo "ERROR: 'find' in PATH appears to be GNU find, not BSD find." >&2
  echo "       This script uses BSD find flags (e.g. -perm +111)." >&2
  echo "       Ensure /usr/bin precedes homebrew prefixes in PATH, or" >&2
  echo "       resolve the conflict (e.g. 'brew unlink findutils')." >&2
  exit 1
fi

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
  --stage-experimental   Copy current packages/ into ~/opt/proven-experimental/
                         (local-only cache used as an overlay on top of proven/,
                         takes precedence for any dep present in both)
  --clear-experimental   Remove the experimental cache for this architecture
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
  # Fail-open if no sidecar exists (legacy cache); fail-closed on mismatch.
  local pkg_file="$1"
  local sha_file="${pkg_file}.sha256"

  if [[ ! -f "${sha_file}" ]]; then
    echo "    WARNING: no .sha256 sidecar for ${pkg_file:t} — accepting (legacy cache)"
    return 0
  fi

  if (cd "${pkg_file:h}" && shasum -a 256 -c "${sha_file:t}" >/dev/null 2>&1); then
    return 0
  else
    echo "    ERROR: SHA256 mismatch on ${pkg_file:t}"
    echo "      Expected (from ${sha_file:t}): $(cat "${sha_file}")"
    echo "      Actual:                       $(shasum -a 256 "${pkg_file}")"
    return 1
  fi
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

  # Copy to local cache
  mkdir -p "${local_proven}"
  echo "    Copying ${#pointer_files[@]} packages to ${local_proven}..."
  command cp "${repo_proven}"/*.tar.gz "${local_proven}/"

  # Clean up repo working copy
  cleanup_repo_lfs "${ARCH_LABEL}"

  echo "==> Done. ${#pointer_files[@]} packages restored to ${local_proven}"
  echo "    Run './build-local.sh <tag>' to build using cached deps."
}

function restore_from_proven {
  local proven_dir="${TARGET}/proven/${ARCH_LABEL}"
  local experimental_dir="${TARGET}/proven-experimental/${ARCH_LABEL}"
  local restored=0
  local missing=()
  local pkg pkg_file

  if [[ -d "${experimental_dir}" ]]; then
    echo "==> Restoring from proven cache (with experimental overlay)..."
  else
    echo "==> Restoring from proven cache..."
  fi

  # First pass: confirm every expected package is available in at least one cache
  for pkg in "${EXPECTED_PACKAGES[@]}"; do
    if [[ ! -f "${experimental_dir}/${pkg}.tar.gz" ]] && [[ ! -f "${proven_dir}/${pkg}.tar.gz" ]]; then
      echo "    Missing: ${pkg}"
      missing+=("${pkg}")
    fi
  done

  if [[ ! -f "${experimental_dir}/docbook-xsl.tar.gz" ]] && [[ ! -f "${proven_dir}/docbook-xsl.tar.gz" ]]; then
    echo "    Missing: docbook-xsl"
    missing+=("docbook-xsl")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "==> Restored ${restored} packages. Missing: ${#missing[@]}."
    return 1
  fi

  # Restore pass: experimental takes precedence over proven for any package present in both
  for pkg in "${EXPECTED_PACKAGES[@]}"; do
    if [[ -f "${experimental_dir}/${pkg}.tar.gz" ]]; then
      pkg_file="${experimental_dir}/${pkg}.tar.gz"
      echo "    Restoring ${pkg} (experimental)..."
    else
      pkg_file="${proven_dir}/${pkg}.tar.gz"
      echo "    Restoring ${pkg}..."
    fi
    verify_pkg_sha256 "${pkg_file}" || return 1
    (cd "${TARGET}" && tar xzf "${pkg_file}")
    restored=$((restored + 1))
  done

  if [[ -f "${experimental_dir}/docbook-xsl.tar.gz" ]]; then
    echo "    Restoring docbook-xsl (experimental)..."
    verify_pkg_sha256 "${experimental_dir}/docbook-xsl.tar.gz" || return 1
    (cd "${TARGET}" && tar xzf "${experimental_dir}/docbook-xsl.tar.gz")
  else
    echo "    Restoring docbook-xsl..."
    verify_pkg_sha256 "${proven_dir}/docbook-xsl.tar.gz" || return 1
    (cd "${TARGET}" && tar xzf "${proven_dir}/docbook-xsl.tar.gz")
  fi
  restored=$((restored + 1))

  echo "==> Restored ${restored} packages. Missing: 0."
  return 0
}

function do_stage_experimental {
  local experimental_dir="${TARGET}/proven-experimental/${ARCH_LABEL}"
  local proven_dir="${TARGET}/proven/${ARCH_LABEL}"
  local packages_dir="${TARGET}/packages"
  local pkg_files=("${packages_dir}"/*.tar.gz)
  local pkg_file name
  local staged=0 skipped=0

  if [[ ! -d "${packages_dir}" ]] || [[ ${#pkg_files[@]} -eq 0 ]]; then
    echo "ERROR: No packages found in ${packages_dir}."
    echo "       Run a build first, then --stage-experimental."
    exit 1
  fi

  echo "==> Staging experimental cache for ${ARCH_LABEL}..."
  mkdir -p "${experimental_dir}"

  # Skip any package whose filename already exists in proven/ — the overlay
  # falls back to proven for anything missing from experimental, so
  # duplicating those is wasted disk.
  for pkg_file in "${pkg_files[@]}"; do
    name="${pkg_file:t}"
    if [[ -f "${proven_dir}/${name}" ]]; then
      echo "    Skipping ${name} (already in proven)"
      skipped=$((skipped + 1))
    else
      command cp "${pkg_file}" "${experimental_dir}/"
      echo "    Staged ${name}"
      staged=$((staged + 1))
    fi
  done

  echo "==> Staged ${staged} new package(s), skipped ${skipped} already in proven."
  if [[ ${staged} -gt 0 ]]; then
    echo "    Subsequent builds on this machine will use these instead of proven."
    echo "    Run --clear-experimental to revert to proven only."
  fi
}

function do_clear_experimental {
  local experimental_dir="${TARGET}/proven-experimental/${ARCH_LABEL}"

  if [[ ! -d "${experimental_dir}" ]]; then
    echo "==> No experimental cache for ${ARCH_LABEL}."
    return 0
  fi

  echo "==> Clearing experimental cache for ${ARCH_LABEL}..."
  command rm -rf "${experimental_dir}"
  echo "==> Cleared. Future builds use proven cache only."
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

  # Precondition: packages must contain all expected deps + docbook-xsl
  for pkg in "${EXPECTED_PACKAGES[@]}"; do
    [[ -f "${packages_dir}/${pkg}.tar.gz" ]] || missing_pkgs+=("${pkg}")
  done
  [[ -f "${packages_dir}/docbook-xsl.tar.gz" ]] || missing_pkgs+=("docbook-xsl")
  if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
    echo "ERROR: Cannot promote — packages/ is incomplete (${#missing_pkgs[@]} missing)."
    echo "  Missing: ${missing_pkgs[*]}"
    echo "  This can happen after a smart-restore build (only mkvtoolnix was rebuilt)."
    echo "  Run a --full build first, then promote."
    exit 1
  fi

  echo "==> Promoting ${#EXPECTED_PACKAGES[@]} packages + docbook-xsl (${ARCH_LABEL})..."

  # Step 1: Archive current proven to LFS
  local proven_files=("${proven_dir}"/*.tar.gz)
  if [[ -d "${proven_dir}" ]] && [[ ${#proven_files[@]} -gt 0 ]]; then
    echo "    Archiving current ${ARCH_LABEL} proven to LFS..."
    mkdir -p "${repo_proven}"
    command cp "${proven_dir}"/*.tar.gz "${repo_proven}/"
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
      command rm -f "${existing}" "${existing}.sha256"
    fi
  done
  command cp "${proven_dir}"/*.tar.gz "${repo_proven}/"
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

# Parse arguments
while [[ -n $1 ]]; do
  case $1 in
    --full)                BUILD_MODE="full" ;;
    --promote)             BUILD_MODE="promote" ;;
    --restore-cache)       BUILD_MODE="restore-cache" ;;
    --cleanup-lfs)         BUILD_MODE="cleanup-lfs" ;;
    --stage-experimental)  BUILD_MODE="stage-experimental" ;;
    --clear-experimental)  BUILD_MODE="clear-experimental" ;;
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

# Handle experimental cache ops early (no tag, clone, or specs needed)
if [[ "${BUILD_MODE}" == "stage-experimental" ]]; then
  do_stage_experimental
  exit $?
fi

if [[ "${BUILD_MODE}" == "clear-experimental" ]]; then
  do_clear_experimental
  exit $?
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
echo "==> Config: QTVER=${QTVER}, TARGET=${TARGET}, WORK_DIR=${WORK_DIR}"

# Verify QTVER matches what specs.sh will download
SPECS_QT_FILE="${spec_qt[1]}"
EXPECTED_QT_DIR="qt-everywhere-src-${QTVER}"
if [[ "${SPECS_QT_FILE}" != "${EXPECTED_QT_DIR}.tar.xz" ]]; then
  echo "ERROR: Qt version mismatch!"
  echo "  QTVER=${QTVER} expects: ${EXPECTED_QT_DIR}.tar.xz"
  echo "  specs.sh has: ${SPECS_QT_FILE}"
  echo "  Fix: update QTVER in config/config.local.sh to match specs-updates.patch"
  exit 1
fi
echo "==> Verified: QTVER=${QTVER} matches specs.sh (${SPECS_QT_FILE})"

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
EXPECTED_PACKAGES=()
for spec_var in "${EXPECTED_SPEC_VARS[@]}"; do
  filename="${${(P)spec_var}[1]}"
  if [[ -z "${filename}" ]]; then
    echo "ERROR: ${spec_var} not found in specs.sh — upstream may have renamed it"
    echo "  Check the upstream specs.sh and update EXPECTED_SPEC_VARS"
    exit 1
  fi
  pkg="${filename%%.tar.*}"
  EXPECTED_PACKAGES+=("${pkg}")
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
    wipe_workspace
    if restore_from_proven; then
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
    # Note: -perm +111 is BSD find syntax (deprecated but macOS command find doesn't support -perm /111)
    done < <(command find "${DMG_APP}/Contents/MacOS" \( -name "*.dylib" -o -type f -perm +111 \) -not -type d -print0 2>/dev/null)
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
  app_bytes=$(command find "${DMG_APP}" -type f -exec command stat -f '%z' {} + 2>/dev/null | awk '{s+=$1} END {print s}')
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
  leak_found=false
  for lib in "${DMG_APP}/Contents/MacOS/libs/"*.dylib "${DMG_APP}/Contents/MacOS/"mkvtoolnix-gui; do
    leaks=$(otool -L "$lib" 2>/dev/null | grep -E "/opt/homebrew|/usr/local/opt" || true)
    if [[ -n "$leaks" ]]; then
      echo "    FAIL: External library reference in $(basename $lib):"
      echo "$leaks" | while read -r line; do echo "      $line"; done
      leak_found=true
      VERIFY_PASSED=false
    fi
  done
  if [[ "$leak_found" == false ]]; then
    echo "    PASS: No Homebrew/external library references"
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

  # Release-ready DMG (no branch suffix) — only emit on main. Other branches
  # would produce a file that looks releasable but isn't; preventing the copy
  # removes that footgun.
  if [[ "${BRANCH}" == "main" ]]; then
    command cp "${DMG_PATH}" "${RELEASE_DIR}/${DMG_RELEASE_NAME}"
    (cd "${RELEASE_DIR}" && shasum -a 256 "${DMG_RELEASE_NAME}" > "${DMG_RELEASE_NAME}.sha256")
  fi

  echo "==> Done!"
  echo "    Build output: ${DMG_PATH}"
  echo "    Internal: ${BUILD_DIR}/${DMG_NAME}"
  echo "    SHA256:   ${BUILD_DIR}/${DMG_NAME}.sha256"
  if [[ "${BRANCH}" == "main" ]]; then
    echo "    Release:  ${RELEASE_DIR}/${DMG_RELEASE_NAME}"
    echo "    SHA256:   ${RELEASE_DIR}/${DMG_RELEASE_NAME}.sha256"
  else
    echo "    Release:  (skipped — not on main)"
  fi
  echo "    Log:      ${LOG_DIR}/${LOG_NAME}"
else
  echo "==> DMG not found at expected path. Check ${WORK_DIR} for output."
  command ls -la "${WORK_DIR}"/MKVToolNix*.dmg 2>/dev/null || true
fi
