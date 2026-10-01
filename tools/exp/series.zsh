# Series builds: named changes, pins, and the source a series build compiles.
#
# A change is a folder, MTX_EXP_CHANGES/<name>/, holding any of:
#
#   branch       one line: a branch in the clone whose own commits apply
#   *.patch      patches applied to the source with git apply
#   packaging/   copied over the source's packaging/ folder: a library patch
#                in packaging/macos/<library>-patches/, or an edited
#                packaging/macos/config.sh
#
# Which libraries a change affects is not declared; the library keys follow
# from the source it produces (keys.zsh). The clone named by MTX_EXP_UPSTREAM
# is only read. Sourced by tools/build-exp.sh; defines functions and globals
# only.

typeset -ga EXP_CHANGES=()
typeset -gA EXP_CHANGE_HASH EXP_CHANGE_BRANCH EXP_CHANGE_COMMITS
: ${EXP_UPSTREAM_REMOTE:=upstream}

# _exp_change_hash <change-dir>
# Of every file in the folder, by its path relative to the folder and its
# content, so any edit, addition or removal moves it.
_exp_change_hash() {
  setopt local_options pipe_fail
  local dir="$1" f sum total
  local -a lines=()
  for f in "${dir}"/**/*(DN^/); do
    if ! sum=$(command shasum -a 256 < "${f}" | command cut -d' ' -f1) || [[ -z "${sum}" ]]; then
      print -u2 "ERROR: cannot hash ${f}"
      return 1
    fi
    lines+=("${sum}  ${f#${dir}/}")
  done
  if ! total=$(print -rl -- "${lines[@]}" | LC_ALL=C command sort | command shasum -a 256 | command cut -d' ' -f1) \
     || [[ -z "${total}" ]]; then
    print -u2 "ERROR: cannot hash the change folder ${dir}"
    return 1
  fi
  print -r -- "${total}"
}

# exp_changes_load_list <changes-root> <comma-separated names>
# Loads the named changes into EXP_CHANGES sorted by name, so the same set in
# any order is the same build; sets EXP_CHANGE_HASH for each and
# EXP_CHANGE_BRANCH for each holding a branch file. EXP_CHANGE_COMMITS is
# emptied for the caller to fill from exp_source_commits.
exp_changes_load_list() {
  local LC_ALL=C   # name order and glob order must not depend on the locale
  local root="$1" list="$2" name dir branch entry name_re='^[a-z0-9][a-z0-9_.-]*$'
  local -a names patches
  EXP_CHANGES=(); EXP_CHANGE_HASH=(); EXP_CHANGE_BRANCH=(); EXP_CHANGE_COMMITS=()
  [[ -n "${list}" ]] || return 0
  names=( ${(s:,:)list} )
  if [[ ${#${(u)names}} -ne ${#names} ]]; then
    print -u2 "ERROR: --with names a change more than once: ${list}"
    return 1
  fi
  for name in ${(o)names}; do
    if [[ ! "${name}" =~ ${name_re} ]]; then
      print -u2 "ERROR: '${name}' is not a change name (lower-case letters, digits, '.', '_', '-')"
      return 1
    fi
    dir="${root}/${name}"
    if [[ ! -d "${dir}" ]]; then
      print -u2 "ERROR: no change named ${name}: ${dir} is not a folder"
      return 1
    fi
    for entry in "${dir}"/*(DN); do
      # a leading dot is refused outright: the patch glob skips dotfiles, so a
      # hidden .patch would be hashed and never applied
      if [[ "${entry:t}" == .* ]]; then
        print -u2 "ERROR: change ${name}: ${entry:t} is not something a change can hold (a branch file, .patch files, a packaging/ folder); remove or rename it"
        return 1
      fi
      if [[ "${entry:t}" == branch && -f "${entry}" && ! -L "${entry}" ]]; then continue; fi
      if [[ "${entry:t}" == *.patch && -f "${entry}" && ! -L "${entry}" ]]; then continue; fi
      if [[ "${entry:t}" == packaging && -d "${entry}" && ! -L "${entry}" ]]; then continue; fi
      print -u2 "ERROR: change ${name}: ${entry:t} is not something a change can hold (a branch file, .patch files, a packaging/ folder); remove or rename it"
      return 1
    done
    patches=( "${dir}"/*.patch(N) )
    if [[ ! -f "${dir}/branch" && ${#patches[@]} -eq 0 && ! -d "${dir}/packaging" ]]; then
      print -u2 "ERROR: change ${name} holds nothing to apply: ${dir} has no branch file, no .patch file and no packaging/ folder"
      return 1
    fi
    if [[ -f "${dir}/branch" ]]; then
      branch=$(<"${dir}/branch")
      if [[ -z "${branch}" || "${branch}" == *[[:space:]]* ]]; then
        print -u2 "ERROR: ${dir}/branch must hold one branch name"
        return 1
      fi
      EXP_CHANGE_BRANCH[${name}]="${branch}"
    fi
    EXP_CHANGE_HASH[${name}]=$(_exp_change_hash "${dir}") || return 1
    EXP_CHANGES+=("${name}")
  done
}

# exp_resolve_pin <repo> <ref> — the commit a branch, tag or SHA names in a clone
exp_resolve_pin() {
  local repo="$1" ref="$2" sha
  if ! sha=$(git -C "${repo}" rev-parse --verify --quiet "${ref}^{commit}"); then
    print -u2 "ERROR: pin '${ref}' is not a commit in ${repo}; if it is new upstream, fetch it: git -C ${repo} fetch --all --tags"
    return 1
  fi
  print -r -- "${sha}"
}

# exp_source_commits <repo> <branch>
# The branch's own commits, oldest first: those in no ${EXP_UPSTREAM_REMOTE}
# remote-tracking ref. A series build applies commits only; uncommitted work
# in the branch's worktree is what try mode builds. Each commit is applied as
# its own patch, and a merge has none (format-patch emits another commit's
# diff in its place), so a branch with a merge among its own is refused.
exp_source_commits() {
  local repo="$1" branch="$2" out merges c
  local -a short=()
  if ! git -C "${repo}" rev-parse --verify --quiet "refs/heads/${branch}^{commit}" >/dev/null; then
    print -u2 "ERROR: branch ${branch} not found in ${repo}"
    return 1
  fi
  if ! git -C "${repo}" remote get-url "${EXP_UPSTREAM_REMOTE}" >/dev/null; then
    print -u2 "ERROR: a change with a branch needs a remote named '${EXP_UPSTREAM_REMOTE}' in ${repo}, pointing at upstream MKVToolNix"
    return 1
  fi
  out=$(git -C "${repo}" rev-list --reverse "refs/heads/${branch}" --not --remotes="${EXP_UPSTREAM_REMOTE}") || return 1
  if [[ -z "${out}" ]]; then
    print -u2 "ERROR: branch ${branch} has no commits of its own"
    return 1
  fi
  merges=$(git -C "${repo}" rev-list --merges "refs/heads/${branch}" --not --remotes="${EXP_UPSTREAM_REMOTE}") || return 1
  if [[ -n "${merges}" ]]; then
    for c in ${(f)merges}; do short+=("${c[1,12]}"); done
    print -u2 "ERROR: branch ${branch} has merge commits among its own (${(j:, :)short}); a series build applies a branch's commits one at a time as patches, and a merge is not one"
    print -u2 "To fix it, rebase the branch onto the pin, then rebuild"
    return 1
  fi
  print -r -- "${out}"
}

# _exp_unpack <dir> <git arguments...>
# Unpacks the tar archive `git <arguments>` writes into <dir>; fails when
# either side fails.
_exp_unpack() {
  local dir="$1"; shift
  local -a rcs
  git "$@" | command tar -x -f - -C "${dir}"
  rcs=( "${pipestatus[@]}" )
  [[ "${rcs[1]}" == 0 && "${rcs[2]}" == 0 ]]
}

# _exp_apply <dest> <patch-text>
# Checks, then applies, one patch to the plain files in <dest>. On failure it
# prints git's own complaint (the file that does not match) on stderr. Run
# inside a repository, git apply would patch only paths below the folder it
# runs in and skip the rest without an error; GIT_CEILING_DIRECTORIES stops it
# looking for one above <dest>.
_exp_apply() {
  local dest="$1" text="$2" ceiling err
  ceiling="${dest:A:h}"
  if ! err=$( (cd "${dest}" && GIT_CEILING_DIRECTORIES="${ceiling}" git apply --check) 2>&1 <<< "${text}" ); then
    print -u2 -r -- "${err}"
    return 1
  fi
  if ! err=$( (cd "${dest}" && GIT_CEILING_DIRECTORIES="${ceiling}" git apply) 2>&1 <<< "${text}" ); then
    print -u2 -r -- "${err}"
    return 1
  fi
}

# exp_apply_staging_patch <source-dir> <patch-file>
# Puts the staging patch (packaging/macos/myinstall.sh stages under
# STAGING_DIR) in a staged source of either mode, and prints its state:
# already_present when it reverses cleanly, applied when it applies; refuses a
# source it does neither to. As in _exp_apply, GIT_CEILING_DIRECTORIES keeps
# all three git apply runs from finding a repository above <source-dir>,
# where a patch path outside the folder would be skipped with exit 0.
exp_apply_staging_patch() {
  local dest="$1" patch="${2:A}"
  local -x GIT_CEILING_DIRECTORIES="${dest:A:h}"
  if (cd "${dest}" && git apply --check -R "${patch}" 2>/dev/null); then
    print -r -- already_present
  elif (cd "${dest}" && git apply --check "${patch}"); then
    (cd "${dest}" && git apply "${patch}") || return 1
    print -r -- applied
  else
    print -u2 "ERROR: ${patch:t} does not apply to this source's packaging/macos/myinstall.sh"
    return 1
  fi
}

# exp_prepare_source <repo> <pin-sha> <dest> <changes-root>
# Fills <dest>, which must not exist, with plain files: the pin's tree from
# <repo>, each submodule's tree at the commit the pin records, from <repo>'s
# own module repositories, then EXP_CHANGES in name order — each change's
# branch commits, its .patch files, then its packaging/ folder. Nothing is
# written to <repo>.
exp_prepare_source() {
  local LC_ALL=C   # patch files apply in the same order in every locale
  local repo="$1" pin="$2" dest="$3" root="$4" gitdir listing line key sub_name sub_path entry sha mod name c f text err
  local -a commits modes
  if [[ -e "${dest}" ]]; then
    print -u2 "ERROR: ${dest} already exists"
    return 1
  fi
  gitdir=$(git -C "${repo}" rev-parse --path-format=absolute --git-common-dir) || return 1
  command mkdir -p "${dest}" || return 1
  if ! _exp_unpack "${dest}" -C "${repo}" archive "${pin}"; then
    print -u2 "ERROR: cannot unpack pin ${pin[1,12]} from ${repo}"
    return 1
  fi
  if [[ -f "${dest}/.gitmodules" ]]; then
    listing=$(git config -f "${dest}/.gitmodules" --get-regexp '^submodule\..*\.path$') || {
      print -u2 "ERROR: cannot read the submodule paths in the .gitmodules of pin ${pin[1,12]}"
      return 1
    }
    for line in "${(@f)listing}"; do
      key="${line%% *}"; sub_path="${line#* }"
      sub_name="${${key#submodule.}%.path}"
      entry=$(git -C "${repo}" ls-tree "${pin}" -- "${sub_path}") || return 1
      if [[ "${entry}" != "160000 commit "* ]]; then
        print -u2 "ERROR: pin ${pin[1,12]} records no submodule commit at ${sub_path}"
        return 1
      fi
      sha="${${entry#160000 commit }%%$'\t'*}"
      mod="${gitdir}/modules/${sub_name}"
      if [[ ! -d "${mod}" ]]; then
        print -u2 "ERROR: submodule ${sub_path} has no repository at ${mod}; initialize it: git -C ${repo} submodule update --init"
        return 1
      fi
      if ! git --git-dir="${mod}" cat-file -e "${sha}^{commit}"; then
        print -u2 "ERROR: ${mod} lacks commit ${sha[1,12]}, which pin ${pin[1,12]} records for ${sub_path}; fetch it: git --git-dir=${mod} fetch"
        return 1
      fi
      command mkdir -p "${dest}/${sub_path}" || return 1
      if ! _exp_unpack "${dest}/${sub_path}" --git-dir="${mod}" archive "${sha}"; then
        print -u2 "ERROR: cannot unpack ${sub_path} at ${sha[1,12]} from ${mod}"
        return 1
      fi
    done
  fi
  for name in "${EXP_CHANGES[@]}"; do
    if [[ -n "${EXP_CHANGE_BRANCH[${name}]:-}" && -z "${EXP_CHANGE_COMMITS[${name}]:-}" ]]; then
      print -u2 "ERROR: change ${name}: the commits of branch ${EXP_CHANGE_BRANCH[${name}]} were not resolved"
      return 1
    fi
    commits=( ${(f)EXP_CHANGE_COMMITS[${name}]:-} )
    for c in "${commits[@]}"; do
      # A submodule's commit is a gitlink (mode 160000). git apply skips a
      # gitlink change on plain files and exits 0, so the commit's own record
      # is read for one before its patch is applied.
      listing=$(git -C "${repo}" diff-tree -r --root --no-commit-id "${c}") || return 1
      for line in "${(@f)listing}"; do
        modes=( ${=${line%%$'\t'*}} )
        if [[ "${modes[1]}" == :160000 || "${modes[2]}" == 160000 ]]; then
          print -u2 "ERROR: change ${name}: commit ${c[1,12]} changes the commit of submodule ${line#*$'\t'}, which git apply would skip; a series build takes every submodule at the commit the pin records"
          print -u2 "To build a submodule at another commit, build a worktree that has it in try mode (--source)"
          return 1
        fi
      done
      text=$(git -C "${repo}" format-patch -1 --stdout "${c}") || return 1
      if ! err=$(_exp_apply "${dest}" "${text}" 2>&1); then
        print -u2 "ERROR: change ${name}: commit ${c[1,12]} does not apply at pin ${pin[1,12]}"
        print -u2 -r -- "${err}"
        print -u2 "To fix it, rebase the change onto the pin, then rebuild"
        return 1
      fi
    done
    for f in "${root}/${name}"/*.patch(N); do
      text=$(command cat "${f}") || return 1
      if ! err=$(_exp_apply "${dest}" "${text}" 2>&1); then
        print -u2 "ERROR: change ${name}: ${f:t} does not apply at pin ${pin[1,12]}"
        print -u2 -r -- "${err}"
        print -u2 "To fix it, rebase the change onto the pin, then rebuild"
        return 1
      fi
    done
    if [[ -d "${root}/${name}/packaging" ]]; then
      command mkdir -p "${dest}/packaging" || return 1
      command cp -R "${root}/${name}/packaging/." "${dest}/packaging/" || return 1
    fi
  done
}

# exp_check_staged_config <source-dir>
# tools/build-exp.sh stages the wrapper's config/config.exp.local.sh as
# packaging/macos/config.local.sh, replacing whatever is there. One that the
# changes put in the source — a packaging/ folder, a .patch or a commit — would
# be recorded with the build and have no effect on it; refuse it. For series
# builds: a try build's tree may hold one left by a release build, and staging
# replaces it there as intended.
exp_check_staged_config() {
  local f="$1/packaging/macos/config.local.sh"
  if [[ -e "${f}" || -L "${f}" ]]; then
    print -u2 "ERROR: the source prepared from the pin and its changes holds packaging/macos/config.local.sh (${f}); the build replaces that file with the wrapper's config/config.exp.local.sh, so what it sets would have no effect"
    print -u2 "To fix it, put the settings in packaging/macos/config.sh instead: an edited copy in the change's packaging/ folder, or a .patch"
    return 1
  fi
}

# exp_check_root <root> <prefix>
# <root> and <prefix> are MTX_EXP_ROOT and TARGET, symlinks resolved, as
# tools/build-exp.sh checked them at startup. It reads the staged config.sh
# and the overlay again before building, and the overlay derives every build
# location from MTX_EXP_ROOT, so a root exported there would move the prefix,
# the workspace and the cache past those checks: refuse unless both are still
# what was checked. Run in either mode, before keys, wipe or build.
exp_check_root() {
  local root="$1" prefix="$2" root_now="" prefix_now=""
  [[ -n "${MTX_EXP_ROOT:-}" ]] && root_now="${MTX_EXP_ROOT:A}"
  [[ -n "${TARGET:-}" ]] && prefix_now="${TARGET:A}"
  if [[ -z "${root}" || -z "${prefix}" || "${root_now}" != "${root}" || "${prefix_now}" != "${prefix}" ]]; then
    print -u2 "ERROR: reading the staged packaging/macos/config.sh and config.local.sh moved the experimental build locations:"
    print -u2 "         MTX_EXP_ROOT  checked at startup: ${root:-<unset>}  now: ${root_now:-<unset>}"
    print -u2 "         TARGET        checked at startup: ${prefix:-<unset>}  now: ${prefix_now:-<unset>}"
    print -u2 "       A change, or the source's packaging/macos/config.sh, must not set MTX_EXP_ROOT or the build locations; remove that setting, then rebuild"
    return 1
  fi
}

# exp_check_patch_dirs <packaging-dir>
# A <x>-patches/ folder patches library <x>. Only the libraries in EXP_ORDER
# have a key, so a patch for any other would change a build without moving any
# key; refuse it.
exp_check_patch_dirs() {
  local dir="$1" d lib
  for d in "${dir}"/*-patches(N/); do
    lib="${${d:t}%-patches}"
    if (( ! ${EXP_ORDER[(Ie)${lib}]} )); then
      print -u2 "ERROR: ${d} patches '${lib}', which no library key covers, so the build could change without any key showing it; changes may patch: ${EXP_ORDER[*]}"
      return 1
    fi
  done
}
