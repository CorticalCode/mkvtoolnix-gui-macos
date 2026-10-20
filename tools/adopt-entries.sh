#!/bin/zsh
# Lists the entries of a build root that no build recorded creating. With
# --adopt, records them as build output, so later builds may remove them.
# Adopting is a person's decision that each listed entry is build output and
# nothing else: read the listing first.
#
# Usage: ./tools/adopt-entries.sh <root> [--adopt]     (root: /opt/mtx or /opt/mtx-exp)
if [[ -z "${ZSH_VERSION}" ]]; then
  echo "ERROR: This script requires zsh. Run it with: ./tools/adopt-entries.sh" >&2
  exit 1
fi
set -e
setopt NULL_GLOB
unalias -a 2>/dev/null || true

SCRIPT_DIR=${0:a:h:h}
source "${SCRIPT_DIR}/tools/lib/run-record.zsh"

usage() {
  print -u2 "Usage: ./tools/adopt-entries.sh <root> [--adopt]     (root: /opt/mtx or /opt/mtx-exp)"
  exit 1
}
[[ $# -ge 1 && $# -le 2 ]] || usage
ROOT="$1"; ADOPT=0
if [[ $# -eq 2 ]]; then
  [[ "$2" == --adopt ]] || usage
  ADOPT=1
fi
if [[ "${ROOT}" != /* || ! -d "${ROOT}" ]]; then
  print -u2 "ERROR: ${ROOT} is not an existing folder given by its absolute path"
  exit 1
fi
ROOT="${ROOT:A}"

if (( ADOPT )); then
  run_log_start "${MTX_LOG_DIR:-${SCRIPT_DIR}/logs}" adopt-entries || exit 1
fi
_run_unknown "${ROOT}" || exit 1
if (( ${#RUN_LOGS_FOUND} )); then
  print "Logs the next build will move to the logs folder (never removed):"
  printf '    %s\n' "${RUN_LOGS_FOUND[@]/#/${ROOT}/}"
fi
if (( ! ${#RUN_UNKNOWN} )); then
  print "No entry of ${ROOT} needs adopting."
  exit 0
fi
print "Entries of ${ROOT} no build recorded creating:"
printf '    %s\n' "${RUN_UNKNOWN[@]/#/${ROOT}/}"
if (( ! ADOPT )); then
  print "Nothing was changed. After looking at each one, record them as build output with:"
  print "    ./tools/adopt-entries.sh ${ROOT} --adopt"
  exit 0
fi
run_adopt "${ROOT}" || exit 1
print "Adopted ${#RUN_UNKNOWN} entries; the record is ${ROOT}/run-records/${RUN_ID}.txt"
