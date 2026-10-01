# Try builds: what the manifest records about the source tree a try build
# compiles as it is.
#
# A repository is recorded only when the tree is the top of one; a plain
# folder inside some other work tree is not that repository's commit. The
# uncommitted-work hash covers everything beyond the commit that the build
# stages: tracked changes, and untracked files that are not ignored, by path
# and content, in the tree and in every submodule checked out in it, at any
# depth. Sourced by tools/build-exp.sh; defines functions and globals only.

typeset -g EXP_TRY_REF="" EXP_TRY_SHA="" EXP_TRY_DIRTY=""

# exp_try_record <source-dir>
# Sets EXP_TRY_REF and EXP_TRY_SHA when <source-dir> is the top of a work tree,
# and EXP_TRY_DIRTY when that tree or a submodule in it differs from its
# commit; each stays empty otherwise.
exp_try_record() {
  setopt local_options pipe_fail
  local src="$1" top total
  local -a lines=()
  EXP_TRY_REF=""; EXP_TRY_SHA=""; EXP_TRY_DIRTY=""
  # The top of a work tree holds .git, a folder or (worktrees, submodules) a
  # file; a folder without one is no repository's top, whatever encloses it.
  [[ -e "${src}/.git" ]] || return 0
  top=$(git -C "${src}" rev-parse --show-toplevel) || return 1
  [[ "${top:A}" == "${src:A}" ]] || return 0
  EXP_TRY_REF=$(git -C "${src}" rev-parse --abbrev-ref HEAD) || return 1
  EXP_TRY_SHA=$(git -C "${src}" rev-parse HEAD) || return 1
  _exp_try_work "${src}" "" || return 1
  [[ ${#lines[@]} -gt 0 ]] || return 0
  if ! total=$(print -rl -- "${lines[@]}" | LC_ALL=C command sort | command shasum -a 256 | command cut -d' ' -f1) \
     || [[ -z "${total}" ]]; then
    print -u2 "ERROR: cannot hash the uncommitted work in ${src}"
    return 1
  fi
  EXP_TRY_DIRTY="${total}"
}

# _exp_try_work <top> <path>
# Adds to the caller's `lines` the uncommitted work of the repository at
# <top>/<path> (<path> empty for <top> itself): a hash of its tracked changes
# against its HEAD, and each untracked file that is not ignored, by its path
# under <top> and its content. Then does the same for each submodule checked
# out in it. A submodule's own content is hashed there, so here only a change
# of the commit it has checked out counts as a change of this repository.
_exp_try_work() {
  setopt local_options pipe_fail
  local top="$1" rel="$2" dir changes diff_sum listing f sum entry sub
  dir="${top}${rel:+/${rel}}"
  changes=$(git --no-optional-locks -C "${dir}" status --porcelain --untracked-files=all --ignore-submodules=dirty) || return 1
  if [[ -n "${changes}" ]]; then
    diff_sum=$(git --no-optional-locks -C "${dir}" diff HEAD --binary --ignore-submodules=dirty \
               | command shasum -a 256 | command cut -d' ' -f1) || diff_sum=""
    if [[ -z "${diff_sum}" ]]; then
      print -u2 "ERROR: cannot hash the uncommitted changes in ${dir}"
      return 1
    fi
    lines+=("diff ${rel:-.} ${diff_sum}")
    listing=$(git --no-optional-locks -C "${dir}" ls-files -z --others --exclude-standard) || return 1
    for f in "${(@0)listing}"; do
      [[ -n "${f}" ]] || continue
      # git lists an untracked repository inside the tree as its folder and does
      # not look inside; reading a folder hashes nothing, though it is staged.
      if [[ ! -f "${dir}/${f}" ]]; then
        print -u2 "ERROR: cannot record the untracked ${dir}/${f}: not a file (a repository inside the source tree?); move it out of the tree or make it a submodule"
        return 1
      fi
      if ! sum=$(command shasum -a 256 < "${dir}/${f}" | command cut -d' ' -f1) || [[ -z "${sum}" ]]; then
        print -u2 "ERROR: cannot hash the untracked file ${dir}/${f}"
        return 1
      fi
      lines+=("${sum}  ${rel:+${rel}/}${f}")
    done
  fi
  # Submodules are the index's gitlinks (mode 160000). One that is not checked
  # out holds nothing; the build gets it at the commit the tree records.
  listing=$(git --no-optional-locks -C "${dir}" ls-files -z --stage) || return 1
  for entry in "${(@0)listing}"; do
    [[ "${entry}" == "160000 "* ]] || continue
    sub="${entry#*$'\t'}"
    [[ -e "${dir}/${sub}/.git" ]] || continue
    _exp_try_work "${top}" "${rel:+${rel}/}${sub}" || return 1
  done
}
