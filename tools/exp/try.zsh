# Try builds: what the manifest records about the source tree a try build
# compiles as it is.
#
# A repository is recorded only when the tree is the top of one; a plain
# folder inside some other work tree is not that repository's commit. The
# uncommitted-work hash covers everything beyond the commit that the build
# stages: tracked changes, and untracked files that are not ignored, by path
# and content. Sourced by tools/build-exp.sh; defines functions and globals
# only.

typeset -g EXP_TRY_REF="" EXP_TRY_SHA="" EXP_TRY_DIRTY=""

# exp_try_record <source-dir>
# Sets EXP_TRY_REF and EXP_TRY_SHA when <source-dir> is the top of a work tree,
# and EXP_TRY_DIRTY when that tree differs from its commit; each stays empty
# otherwise.
exp_try_record() {
  setopt local_options pipe_fail
  local src="$1" top changes diff_sum listing f sum total
  local -a lines
  EXP_TRY_REF=""; EXP_TRY_SHA=""; EXP_TRY_DIRTY=""
  # The top of a work tree holds .git, a folder or (worktrees, submodules) a
  # file; a folder without one is no repository's top, whatever encloses it.
  [[ -e "${src}/.git" ]] || return 0
  top=$(git -C "${src}" rev-parse --show-toplevel) || return 1
  [[ "${top:A}" == "${src:A}" ]] || return 0
  EXP_TRY_REF=$(git -C "${src}" rev-parse --abbrev-ref HEAD) || return 1
  EXP_TRY_SHA=$(git -C "${src}" rev-parse HEAD) || return 1
  changes=$(git --no-optional-locks -C "${src}" status --porcelain --untracked-files=all --ignore-submodules=dirty) || return 1
  [[ -n "${changes}" ]] || return 0
  diff_sum=$(git -C "${src}" diff HEAD --binary | command shasum -a 256 | command cut -d' ' -f1) || diff_sum=""
  if [[ -z "${diff_sum}" ]]; then
    print -u2 "ERROR: cannot hash the uncommitted changes in ${src}"
    return 1
  fi
  lines=("diff ${diff_sum}")
  listing=$(git -C "${src}" ls-files -z --others --exclude-standard) || return 1
  for f in "${(@0)listing}"; do
    [[ -n "${f}" ]] || continue
    if ! sum=$(command shasum -a 256 < "${src}/${f}" | command cut -d' ' -f1) || [[ -z "${sum}" ]]; then
      print -u2 "ERROR: cannot hash the untracked file ${src}/${f}"
      return 1
    fi
    lines+=("${sum}  ${f}")
  done
  if ! total=$(print -rl -- "${lines[@]}" | LC_ALL=C command sort | command shasum -a 256 | command cut -d' ' -f1) \
     || [[ -z "${total}" ]]; then
    print -u2 "ERROR: cannot hash the uncommitted work in ${src}"
    return 1
  fi
  EXP_TRY_DIRTY="${total}"
}
