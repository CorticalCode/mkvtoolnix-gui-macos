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
# in the branch's worktree is what try mode builds.
exp_source_commits() {
  local repo="$1" branch="$2" out
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

# exp_prepare_source <repo> <pin-sha> <dest> <changes-root>
# Fills <dest>, which must not exist, with plain files: the pin's tree from
# <repo>, each submodule's tree at the commit the pin records, from <repo>'s
# own module repositories, then EXP_CHANGES in name order — each change's
# branch commits, its .patch files, then its packaging/ folder. Nothing is
# written to <repo>.
exp_prepare_source() {
  local repo="$1" pin="$2" dest="$3" root="$4" gitdir listing line key sub_name sub_path entry sha mod name c f text err
  local -a commits
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
