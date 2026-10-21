# Logs, run records and deliberate cleaning for the build scripts. Sourced by
# build-local.sh, tools/build-exp.sh, tools/refresh-deps.sh and
# tools/adopt-entries.sh; defines functions and the variables they share.
#
# Logs. run_log_start sends everything a run prints from then on to a file of
# its own in the logs folder, as well as to the terminal. No log is truncated
# or reused, and run_log_rename keeps the open file, so a renamed log is
# complete.
#
# Run records. A build root (/opt/mtx, /opt/mtx-exp) has three areas: prefix/,
# build/ and stage/. An entry is one top-level name in an area. Each run keeps
# a record, <root>/run-records/<run-id>.txt, whose lines include
#     created <area>/<name>     the run made the entry
#     removed <area>/<name>     the run removed it
#     moved <area>/<name> <to>  a log found in an area, moved to the logs folder
# An entry is owned when the last created or removed line naming it, reading
# the records in run order, says created. Builds remove only owned entries. An
# entry that is not owned stops the run before anything is removed, unless it
# is kept (RUN_KEEP), a .DS_Store or a log: kept entries and .DS_Store files
# stay where they are, and a log is moved to the logs folder.
# tools/adopt-entries.sh is how a person makes an unowned entry owned.
#
# The finish. A script's finish (its report, the record's close) runs once,
# from its EXIT trap through run_finish and from its TRAPZERR through
# run_finish_zerr: under set -e, zsh ends a run without the EXIT trap when a
# command fails inside a function or a function returns non-zero at top level.

typeset -ga RUN_AREAS=(prefix build stage)
# Never removed by a build: the release cache, and the release clone, which its
# own reset manages.
typeset -ga RUN_KEEP=(prefix/proven build/mkvtoolnix-src)
typeset -ga RUN_BEFORE=() RUN_REMOVED=() RUN_TEMP=() RUN_UNKNOWN=() RUN_LOGS_FOUND=()
typeset -gA RUN_OWNED=()
typeset -g RUN_ID="" RUN_LOG="" RUN_LOGS_DIR="" RUN_ROOT="" RUN_RECORD=""
typeset -gi RUN_FINISHED=0

_run_now() { command date -u +%Y-%m-%dT%H:%M:%SZ; }

# run_log_start <logs-dir> <script> [<mode>]
# Creates <logs-dir>/<YYYYmmdd-HHMMSS>-<script>[-<mode>][-<n>].log, the time in
# UTC, a name no file has, and from then on writes everything the shell prints
# to it as well.
# Sets RUN_ID, RUN_LOG and RUN_LOGS_DIR. 1 when no log can be created.
run_log_start() {
  local stem
  local -i n=1
  RUN_LOGS_DIR="$1"
  if ! command mkdir -p "${RUN_LOGS_DIR}" 2>/dev/null; then
    print -u2 "ERROR: cannot create a log in ${RUN_LOGS_DIR}"
    return 1
  fi
  stem="$(command date -u +%Y%m%d-%H%M%S)-$2${3:+-$3}"
  RUN_ID="${stem}"
  until ( setopt no_clobber; : > "${RUN_LOGS_DIR}/${RUN_ID}.log" ) 2>/dev/null; do
    if (( ++n > 99 )); then
      print -u2 "ERROR: cannot create a log in ${RUN_LOGS_DIR}"
      return 1
    fi
    RUN_ID="${stem}-${n}"
  done
  RUN_LOG="${RUN_LOGS_DIR}/${RUN_ID}.log"
  exec > >(command tee -a "${RUN_LOG}") 2>&1
  print -r -- "==> Log: ${RUN_LOG}"
}

# run_log_rename <new-path>
# Renames the log while it is being written. The open file follows a rename on
# the same file system, so the log stays complete; a rename onto an existing
# file or to another file system is refused and the log keeps its name.
run_log_rename() {
  local new="$1" here there
  if [[ -e "${new}" ]]; then
    print -u2 "ERROR: ${new} already exists; the log stays ${RUN_LOG}"
    return 1
  fi
  command mkdir -p "${new:h}" || return 1
  here=$(/usr/bin/stat -f %d "${RUN_LOG}") || return 1
  there=$(/usr/bin/stat -f %d "${new:h}") || return 1
  if [[ "${here}" != "${there}" ]]; then
    print -u2 "ERROR: ${new:h} is on another file system; the log stays ${RUN_LOG}"
    print -u2 "       A log is renamed only within one file system: MTX_LOG_DIR and EXP_KEPT_BUILDS_DIR must be on the same one."
    return 1
  fi
  command mv -n "${RUN_LOG}" "${new}" || return 1
  RUN_LOG="${new}"
  if [[ -n "${RUN_RECORD}" ]]; then
    print -r -- "log ${RUN_LOG}" >> "${RUN_RECORD}" || return 1
  fi
  print -r -- "==> Log: ${RUN_LOG}"
}

# run_finish <function> <exit-status>
# Calls <function> <exit-status> the first time it is called in a run and
# does nothing after that. The EXIT trap calls it: trap 'run_finish fn $?' EXIT
run_finish() {
  (( RUN_FINISHED )) && return 0
  RUN_FINISHED=1
  "$1" "$2" || true
}

# run_finish_zerr <function> <exit-status>
# For a script's TRAPZERR, after its own message: finishes the run when set -e
# is about to end it. Not in a subshell or command substitution, which inherit
# TRAPZERR but whose failure ends only themselves, and not while errexit is
# off, when a failure does not end the run.
run_finish_zerr() {
  (( ZSH_SUBSHELL == 0 )) || return 0
  [[ -o errexit ]] || return 0
  run_finish "$1" "$2" || true
}

# run_report_path — where this run's report goes: beside its log.
run_report_path() { print -r -- "${RUN_LOG%.log}.report.txt"; }

# _run_entries <root> — every entry of every area, hidden ones included, as
# <area>/<name>, one per line.
_run_entries() {
  local area e
  for area in "${RUN_AREAS[@]}"; do
    for e in "$1/${area}"/*(DN); do
      print -r -- "${area}/${e:t}"
    done
  done
}

_run_is_kept()    { (( ${RUN_KEEP[(Ie)$1]} )); }
_run_is_ignored() { [[ "${1:t}" == .DS_Store ]]; }
_run_is_log()     { [[ "$1" == build/* && "${1:t}" == (build-*.log|build-report-*.txt) ]]; }
_run_exists()     { [[ -e "$1" || -L "$1" ]]; }

# _run_owned <root> — sets RUN_OWNED to the entries whose last created or
# removed line, over the root's records in run order, is created. Record names
# start with the run's time, so name order is run order.
_run_owned() {
  local f line
  RUN_OWNED=()
  for f in "$1/run-records"/*.txt(N); do
    while IFS= read -r line || [[ -n "${line}" ]]; do
      case "${line}" in
        "created "*) RUN_OWNED[${line#created }]=1 ;;
        "removed "*) unset "RUN_OWNED[${line#removed }]" ;;
      esac
    done < "${f}" || return 1
  done
}

# _run_unknown <root> — sets RUN_UNKNOWN to the entries that are neither kept,
# ignored, a log nor owned, and RUN_LOGS_FOUND to the logs.
_run_unknown() {
  local e
  RUN_UNKNOWN=(); RUN_LOGS_FOUND=()
  _run_owned "$1" || return 1
  for e in ${(f)"$(_run_entries "$1")"}; do
    _run_is_kept "${e}" && continue
    _run_is_ignored "${e}" && continue
    if _run_is_log "${e}"; then RUN_LOGS_FOUND+=("${e}"); continue; fi
    (( ${+RUN_OWNED[${e}]} )) && continue
    RUN_UNKNOWN+=("${e}")
  done
  return 0
}

# run_record_open <root> <script> [<mode>]
# Starts this run's record and notes the entries there now, so that
# run_record_close can tell what the run made. Needs run_log_start first.
run_record_open() {
  RUN_ROOT="$1"
  if [[ -z "${RUN_ID}" ]]; then
    print -u2 "ERROR: a run record needs the run's log to be started first"
    return 1
  fi
  command mkdir -p "${RUN_ROOT}/run-records" || return 1
  if ! ( setopt no_clobber; : > "${RUN_ROOT}/run-records/${RUN_ID}.txt" ) 2>/dev/null; then
    print -u2 "ERROR: cannot create ${RUN_ROOT}/run-records/${RUN_ID}.txt"
    return 1
  fi
  RUN_RECORD="${RUN_ROOT}/run-records/${RUN_ID}.txt"
  print -rl -- "run ${RUN_ID}" "script $2" "mode ${3:-default}" "log ${RUN_LOG}" "started $(_run_now)" \
    >> "${RUN_RECORD}" || return 1
  RUN_BEFORE=( ${(f)"$(_run_entries "${RUN_ROOT}")"} )
  RUN_REMOVED=()
}

# run_record_close <exit-status>
# Removes the temporary files this run registered that are still there, then
# records each entry that appeared since run_record_open, or that the run
# removed and made again, and how the run ended. A no-op without an open record
# apart from the temporary files; safe to call twice.
run_record_close() {
  local rc="$1" e
  local -a after
  for e in "${RUN_TEMP[@]}"; do
    _run_exists "${e}" || continue
    print -r -- "    Removing ${e} (a temporary file of this run)"
    command rm -rf "${e}"
  done
  RUN_TEMP=()
  [[ -n "${RUN_RECORD}" && -f "${RUN_RECORD}" ]] || return 0
  after=( ${(f)"$(_run_entries "${RUN_ROOT}")"} )
  for e in "${after[@]}"; do
    _run_is_kept "${e}" && continue
    _run_is_ignored "${e}" && continue
    _run_is_log "${e}" && continue
    if (( ! ${RUN_BEFORE[(Ie)${e}]} || ${RUN_REMOVED[(Ie)${e}]} )); then
      print -r -- "created ${e}" >> "${RUN_RECORD}"
    fi
  done
  print -r -- "ended $(_run_now) exit ${rc}" >> "${RUN_RECORD}"
  RUN_RECORD=""
}

# run_temp_add <path> — a temporary file or folder this run made, outside the
# areas; run_record_close removes it if it is still there.
run_temp_add() { RUN_TEMP+=("$1"); }

# run_check_root <root>
# 0: every entry is kept, ignored, a log or owned; each log has been moved to
# the logs folder. 1: some entry is unknown; each is listed, nothing changed.
run_check_root() {
  local root="$1" e
  _run_unknown "${root}" || return 1
  if (( ${#RUN_UNKNOWN} )); then
    print -u2 "ERROR: ${root} holds ${#RUN_UNKNOWN} entries no build recorded creating:"
    for e in "${RUN_UNKNOWN[@]}"; do
      print -u2 "         ${root}/${e}"
    done
    print -u2 "       Nothing was removed. Look at each one; to let builds remove them, run:"
    print -u2 "         ./tools/adopt-entries.sh ${root} --adopt"
    return 1
  fi
  for e in "${RUN_LOGS_FOUND[@]}"; do
    _run_move_log "${root}" "${e}" || return 1
  done
}

# _run_move_log <root> <area/name> — moves a log found in an area to the logs
# folder, under a name no file there has.
_run_move_log() {
  local src="$1/$2" dest
  local -i n=1
  if [[ -z "${RUN_LOGS_DIR}" ]]; then
    print -u2 "ERROR: no logs folder to move ${src} to"
    return 1
  fi
  dest="${RUN_LOGS_DIR}/${2:t}"
  while [[ -e "${dest}" ]]; do
    (( n++ )); dest="${RUN_LOGS_DIR}/${${2:t}:r}-${n}.${${2:t}:e}"
  done
  command mv -n "${src}" "${dest}" || return 1
  print -r -- "    Moved ${src} to ${dest}"
  if [[ -n "${RUN_RECORD}" ]]; then
    print -r -- "moved $2 ${dest}" >> "${RUN_RECORD}" || return 1
  fi
}

# _run_rm <root> <area/name> — removes one entry, printing and recording it.
# Every removal comes through here: it refuses a name that is not exactly
# <area>/<name> of a known area, and kept, ignored and log entries.
_run_rm() {
  local area="${2%%/*}" name="${2#*/}"
  if [[ "$2" != */* ]] || (( ! ${RUN_AREAS[(Ie)${area}]} )) \
     || [[ -z "${name}" || "${name}" == */* || "${name}" == . || "${name}" == .. ]]; then
    print -u2 "ERROR: $1/$2 is not an entry of an area; it was not removed"
    return 1
  fi
  if _run_is_kept "$2" || _run_is_ignored "$2" || _run_is_log "$2"; then
    print -u2 "ERROR: $1/$2 is never removed by a build"
    return 1
  fi
  print -r -- "    Removing $1/$2"
  command rm -rf "$1/$2" || return 1
  RUN_REMOVED+=("$2")
  if [[ -n "${RUN_RECORD}" ]]; then
    print -r -- "removed $2" >> "${RUN_RECORD}" || return 1
  fi
}

# run_remove <root> <area/name>
# Removes an owned entry. Refuses any entry no run recorded creating, and what
# _run_rm refuses; an absent entry is not an error.
run_remove() {
  local root="$1" e="$2"
  _run_exists "${root}/${e}" || return 0
  _run_owned "${root}" || return 1
  if (( ! ${+RUN_OWNED[${e}]} )); then
    print -u2 "ERROR: no build recorded creating ${root}/${e}; it was not removed"
    return 1
  fi
  _run_rm "${root}" "${e}"
}

# run_remove_made <root> <area/name> — removes an entry this run made itself:
# one that was not there when the record was opened.
run_remove_made() {
  local root="$1" e="$2"
  _run_exists "${root}/${e}" || return 0
  if (( ${RUN_BEFORE[(Ie)${e}]} )); then
    print -u2 "ERROR: ${root}/${e} was there before this run; it was not removed"
    return 1
  fi
  _run_rm "${root}" "${e}"
}

# run_clean_area <root> <area> — removes every owned entry of one area, leaving
# kept and ignored ones. Reads the records once. Call after run_check_root.
run_clean_area() {
  local root="$1" area="$2" p e
  _run_owned "${root}" || return 1
  for p in "${root}/${area}"/*(DN); do
    e="${area}/${p:t}"
    _run_is_kept "${e}" && continue
    _run_is_ignored "${e}" && continue
    if (( ! ${+RUN_OWNED[${e}]} )); then
      print -u2 "ERROR: no build recorded creating ${root}/${e}; it was not removed"
      return 1
    fi
    _run_rm "${root}" "${e}" || return 1
  done
}

# run_adopt <root> — records every unknown entry of the root as created, in a
# record of its own, printing each. The caller has shown them to a person.
run_adopt() {
  local root="$1" e
  _run_unknown "${root}" || return 1
  run_record_open "${root}" adopt-entries.sh adopt || return 1
  for e in "${RUN_UNKNOWN[@]}"; do
    print -r -- "created ${e}" >> "${RUN_RECORD}" || return 1
    print -r -- "    Adopted ${root}/${e}"
  done
  run_record_close 0
}
