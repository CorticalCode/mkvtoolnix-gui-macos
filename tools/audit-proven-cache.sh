#!/bin/zsh
# tools/audit-proven-cache.sh — is the cache committed to this repository usable?
#
# The consumer already refuses an incomplete cache, but that check fires on
# whoever tries to restore it: the publisher can commit an unusable set and
# nothing says so. This is the same question asked at publish time, and it is
# cheap enough for CI — it reads sidecars and LFS pointers only, and downloads
# nothing.
#
# Usage:
#   ./tools/audit-proven-cache.sh            # every architecture present
#   ./tools/audit-proven-cache.sh arm        # one
#
# Exit: 0 all audited architectures are publishable · 1 at least one is not
#       2 script error (no proven/ directory at all)

if [[ -z "${ZSH_VERSION}" ]]; then
  echo "ERROR: This script requires zsh. Run it with: ./tools/audit-proven-cache.sh" >&2
  exit 1
fi

set -e
setopt NULL_GLOB
unalias -a 2>/dev/null || true

SCRIPT_DIR=${0:a:h:h}
typeset -i problems=0 audited=0

# The hash a .sha256 sidecar records must equal the OID the LFS pointer names.
# That is checkable without downloading the object: the pointer file IS the
# committed content, and it carries `oid sha256:<hash>`.
_pointer_oid() {
  command sed -n 's/^oid sha256:\([0-9a-f]\{64\}\)$/\1/p' "$1" 2>/dev/null | command head -1
}

audit_arch() {
  local arch="$1"
  local dir="${SCRIPT_DIR}/proven/${arch}"
  local -a tarballs missing_sidecar bad_name bad_oid bad_manifest orphans
  local tgz stem rec_hash rec_name oid m schema kind pkg

  [[ -d "${dir}" ]] || return 0
  tarballs=("${dir}"/*.tar.gz(N))
  audited=$(( audited + 1 ))

  echo "==> proven/${arch}: ${#tarballs[@]} package(s)"
  if [[ ${#tarballs[@]} -eq 0 ]]; then
    echo "    EMPTY — nothing published for this architecture"
    problems=$(( problems + 1 ))
    return 0
  fi

  for tgz in "${tarballs[@]}"; do
    stem="${tgz:t:r:r}"

    # Both sidecars, every package, docbook-xsl included.
    [[ -f "${tgz}.sha256" ]]        || missing_sidecar+=("${stem}: no .sha256")
    [[ -f "${tgz}.manifest.json" ]] || missing_sidecar+=("${stem}: no .manifest.json")

    if [[ -f "${tgz}.sha256" ]]; then
      # `shasum -c` resolves the name inside the record, not the file it was
      # handed, so the recorded name is checked rather than assumed.
      rec_hash=$(command head -1 "${tgz}.sha256" | command awk '{print $1}')
      rec_name=$(command head -1 "${tgz}.sha256" | command awk '{print $NF}')
      [[ "${rec_name}" == "${tgz:t}" ]] || bad_name+=("${stem}: sidecar names ${rec_name}")
      oid=$(_pointer_oid "${tgz}")
      if [[ -n "${oid}" && "${rec_hash}" != "${oid}" ]]; then
        bad_oid+=("${stem}: .sha256 ${rec_hash:0:12}… != LFS oid ${oid:0:12}…")
      fi
    fi

    m="${tgz}.manifest.json"
    if [[ -f "${m}" ]]; then
      schema=$(command grep -oE '"schema_version"[[:space:]]*:[[:space:]]*[0-9]+' "${m}" | command awk '{print $NF}')
      kind=$(command grep -oE '"kind"[[:space:]]*:[[:space:]]*"[^"]*"' "${m}" | command sed -E 's/.*"([^"]*)"$/\1/')
      pkg=$(command grep -oE '"package"[[:space:]]*:[[:space:]]*"[^"]*"' "${m}" | command sed -E 's/.*"([^"]*)"$/\1/')
      [[ "${schema}" == "1" ]]            || bad_manifest+=("${stem}: schema_version=${schema:-<none>}")
      [[ "${kind}" == "proven_cache" ]]   || bad_manifest+=("${stem}: kind=${kind:-<none>}")
      [[ "${pkg}" == "${stem}" ]]         || bad_manifest+=("${stem}: manifest names ${pkg:-<none>}")
    fi
  done

  # A sidecar with no package is a leftover from a pruned dependency. Suffix
  # removal rather than zsh's :r modifier: :r on foo.tar.gz.manifest.json peels
  # one extension at a time, and it is easy to peel one too few or one too many.
  for m in "${dir}"/*.tar.gz.sha256(N); do
    [[ -f "${m%.sha256}" ]] || orphans+=("${m:t}")
  done
  for m in "${dir}"/*.tar.gz.manifest.json(N); do
    [[ -f "${m%.manifest.json}" ]] || orphans+=("${m:t}")
  done

  local -a all=("${missing_sidecar[@]}" "${bad_name[@]}" "${bad_oid[@]}" "${bad_manifest[@]}" "${orphans[@]}")
  if [[ ${#all[@]} -eq 0 ]]; then
    echo "    OK — every package carries a valid .sha256 and .manifest.json"
  else
    for stem in "${all[@]}"; do echo "    FAIL  ${stem}"; done
    problems=$(( problems + ${#all[@]} ))
  fi
}

if [[ -n "$1" ]]; then
  if [[ ! -d "${SCRIPT_DIR}/proven/$1" ]]; then
    echo "ERROR: no proven/$1 in this repository" >&2
    exit 2
  fi
  audit_arch "$1"
else
  for d in "${SCRIPT_DIR}"/proven/*(/N); do
    audit_arch "${d:t}"
  done
fi

if [[ ${audited} -eq 0 ]]; then
  echo "ERROR: no proven/<arch> directories found" >&2
  exit 2
fi

echo ""
if [[ ${problems} -eq 0 ]]; then
  echo "RESULT: ${audited} architecture(s) publishable."
  exit 0
fi
echo "RESULT: ${problems} problem(s). This cache would be refused by anyone restoring it."
echo "        A cache is published by --promote after a full build, which writes the"
echo "        manifests; they cannot honestly be written after the fact."
exit 1
