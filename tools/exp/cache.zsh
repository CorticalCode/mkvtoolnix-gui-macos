# The experimental library cache: one folder per library build, named by key.
#
#   ${EXP_CACHE_ROOT}/<arch>/<library>/<key>/
#       package.tar.gz          the package build.sh made, relative to the prefix
#       package.tar.gz.sha256
#       manifest.json           the inputs the key hashes, the toolchain that
#                               built the package, and when
#
# A store refuses inputs that do not hash to the key, and the checksum guards
# the package from then on; the manifest is written here and read only by
# private tooling. An entry is written into a temporary folder that is renamed
# into place, so an interrupted store leaves no entry. Entries are never
# overwritten. Sourced by tools/build-exp.sh; defines functions only.

_exp_cache_root_set() {
  if [[ -z "${EXP_CACHE_ROOT:-}" ]]; then
    print -u2 "ERROR: EXP_CACHE_ROOT is not set (config/config.exp.local.sh sets it)"
    return 1
  fi
}

# exp_cache_entry <arch> <library> <key>
exp_cache_entry() {
  _exp_cache_root_set || return 1
  print -r -- "${EXP_CACHE_ROOT}/$1/$2/$3"
}

# exp_cache_check <entry-dir>
# 0: intact. 1: no entry. 2: incomplete or damaged — never used, never
# overwritten.
exp_cache_check() {
  setopt local_options pipe_fail
  local entry="$1" recorded actual f
  [[ -e "${entry}" ]] || return 1
  for f in package.tar.gz package.tar.gz.sha256 manifest.json; do
    if [[ ! -f "${entry}/${f}" ]]; then
      print -u2 "ERROR: cache entry ${entry} is incomplete: no ${f}"
      return 2
    fi
  done
  recorded=$(command cut -d' ' -f1 < "${entry}/package.tar.gz.sha256") || return 2
  actual=$(command shasum -a 256 < "${entry}/package.tar.gz" | command cut -d' ' -f1)
  if [[ -z "${actual}" || "${recorded}" != "${actual}" ]]; then
    print -u2 "ERROR: cache entry ${entry}: checksum mismatch (recorded ${recorded:-none}, actual ${actual:-none})"
    return 2
  fi
  return 0
}

# exp_cache_manifest <key> <inputs-text> <built-at> <toolchain>
exp_cache_manifest() {
  local key="$1" inputs="$2" built_at="$3" toolchain="$4" line k v
  local -a fields=()
  for line in "${(@f)inputs}"; do
    k="${line%%=*}"; v="${line#*=}"
    v="${v//\\/\\\\}"; v="${v//\"/\\\"}"
    fields+=("    \"${k}\": \"${v}\"")
  done
  toolchain="${toolchain//\\/\\\\}"; toolchain="${toolchain//\"/\\\"}"
  print -r -- "{"
  print -r -- "  \"schema_version\": 1,"
  print -r -- "  \"kind\": \"exp_library\","
  print -r -- "  \"key\": \"${key}\","
  print -r -- "  \"built_at\": \"${built_at}\","
  print -r -- "  \"toolchain\": \"${toolchain}\","
  print -r -- "  \"inputs\": {"
  print -r -- "${(pj:,\n:)fields}"
  print -r -- "  }"
  print -r -- "}"
}

# exp_cache_store <entry-dir> <key> <package-file> <inputs-text> <built-at> <toolchain>
exp_cache_store() {
  local entry="$1" key="$2" pkg="$3" inputs="$4" built_at="$5" toolchain="$6" tmp sha
  setopt local_options pipe_fail
  if [[ -e "${entry}" ]]; then
    print -u2 "ERROR: cache entry ${entry} already exists; refusing to overwrite it"
    return 1
  fi
  if [[ ! -f "${pkg}" ]]; then
    print -u2 "ERROR: built package ${pkg} not found"
    return 1
  fi
  if [[ "$(print -rn -- "${inputs}" | command shasum -a 256 | command cut -d' ' -f1)" != "${key}" ]]; then
    print -u2 "ERROR: refusing to store ${entry}: its inputs do not hash to its key"
    return 1
  fi
  command mkdir -p "${entry:h}" || return 1
  tmp=$(command mktemp -d "${entry:h}/.incoming.XXXXXX") || return 1
  command cp "${pkg}" "${tmp}/package.tar.gz" || return 1
  sha=$(command shasum -a 256 < "${tmp}/package.tar.gz" | command cut -d' ' -f1)
  [[ -n "${sha}" ]] || return 1
  print -r -- "${sha}  package.tar.gz" > "${tmp}/package.tar.gz.sha256" || return 1
  exp_cache_manifest "${key}" "${inputs}" "${built_at}" "${toolchain}" > "${tmp}/manifest.json" || return 1
  command mv "${tmp}" "${entry}" || return 1
}

# exp_cache_restore <entry-dir> <target>
exp_cache_restore() {
  (cd "$2" && command tar xzf "$1/package.tar.gz")
}

# exp_cache_drop <arch> <library>/<key or its first 12+ characters>
exp_cache_drop() {
  local arch="$1" spec="$2" lib prefix re='^[a-z_]+/[0-9a-f]{12,64}$'
  local -a hits
  _exp_cache_root_set || return 1
  if [[ ! "${spec}" =~ ${re} ]]; then
    print -u2 "ERROR: name the entry as <library>/<key>, with at least 12 characters of the key (its folder under ${EXP_CACHE_ROOT}/${arch}/)"
    return 1
  fi
  lib="${spec%%/*}"; prefix="${spec#*/}"
  hits=( "${EXP_CACHE_ROOT}/${arch}/${lib}/${prefix}"*(N/) )
  if [[ ${#hits[@]} -ne 1 ]]; then
    print -u2 "ERROR: ${#hits[@]} cache entries match ${spec} for ${arch}"
    return 1
  fi
  command rm -rf "${hits[1]}" || return 1
  print -r -- "Removed ${hits[1]}"
}

# exp_cache_clear <arch>
exp_cache_clear() {
  local dir
  _exp_cache_root_set || return 1
  dir="${EXP_CACHE_ROOT}/$1"
  if [[ -d "${dir}" ]]; then
    command rm -rf "${dir}" || return 1
    print -r -- "Cleared ${dir}"
  else
    print -r -- "No cache at ${dir}"
  fi
}

# exp_built_package <package-dir> <library> <tarball>
# The file build.sh's packaging step writes for a library: named after the
# folder it built in, which for cmark (built by CMake in mtx-build/) is
# mtx-build, and for zlib drops the tarball's "v".
exp_built_package() {
  local dir="$1" lib="$2" tarball="$3" name
  case "${lib}" in
    cmark) name="mtx-build" ;;
    *)     name="${tarball%%.tar*}"; name="${name/zlib-v/zlib-}" ;;
  esac
  print -r -- "${dir}/${name}.tar.gz"
}

# exp_archive_docbook <docbook-root> <out-file>
# build.sh unpacks the DocBook stylesheets beside the prefix's other contents
# instead of packaging them; archive them relative to that parent, which is
# where a restore unpacks.
exp_archive_docbook() {
  local root="$1" out="$2" parent="${1:h}"
  local -a dirs
  if [[ ! -L "${root}" && ! -d "${root}" ]]; then
    print -u2 "ERROR: ${root} not found"
    return 1
  fi
  dirs=( "${parent}"/docbook-xsl-*(N/) )
  if [[ ${#dirs[@]} -eq 0 ]]; then
    print -u2 "ERROR: no docbook-xsl-* folder beside ${root}"
    return 1
  fi
  (cd "${parent}" && command tar czf "${out}" "${root:t}" "${dirs[@]:t}")
}
