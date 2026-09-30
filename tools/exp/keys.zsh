# Library-cache keys for experimental builds.
#
# A key names one build of one library. It hashes the inputs that decide what
# that build produces — source, recipe, settings, architecture — and the key of
# the library built before it, so a change to an earlier library moves every
# later key. The toolchain is recorded with each cache entry instead of hashed,
# so an Xcode update does not empty the cache; comparisons check it. Sourced by
# tools/build-exp.sh; defines functions and globals only.

# Libraries build.sh builds that the cache does not hold: gpg is not needed by
# experimental builds, shared_mime_info installs into the prefix without a
# package, and mkvtoolnix is compiled every time.
typeset -ga EXP_UNCACHED=(gpg shared_mime_info mkvtoolnix)

# Variables a library recipe reads from config.sh and config.local.sh.
# Parallelism settings are left out: they change how fast a build runs, not
# what it makes.
typeset -ga EXP_KEY_VARS=(CC CPP CXX CXXCPP CFLAGS CXXFLAGS LDFLAGS QT_CXXFLAGS
                          MACOSX_DEPLOYMENT_TARGET QTVER TARGET)

typeset -ga EXP_ORDER=()
typeset -gA EXP_KEY EXP_INPUT EXP_TARBALL
typeset -g EXP_TOOLCHAIN_ID=""

# exp_build_order <packaging-dir>
# The libraries build.sh builds when given no targets, in its order, without
# the uncached ones — read from its `if [[ -z $@ ]]; then` list.
exp_build_order() {
  local dir="$1" line name in_list=0 re='^  build_([a-z_]+)$'
  local -a order=()
  while IFS= read -r line; do
    if [[ ${in_list} -eq 0 ]]; then
      [[ "${line}" == 'if [[ -z $@ ]]; then' ]] && in_list=1
      continue
    fi
    [[ "${line}" == 'else' ]] && break
    if [[ "${line}" =~ ${re} ]]; then
      name="${match[1]}"
      if (( ! ${EXP_UNCACHED[(Ie)${name}]} )); then
        order+=("${name}")
      fi
    fi
  done < "${dir}/build.sh"
  if [[ ${#order[@]} -eq 0 ]]; then
    print -u2 "ERROR: no build order found in ${dir}/build.sh"
    return 1
  fi
  print -l -- "${order[@]}"
}

# exp_function_text <build.sh> <function>
# One function's definition as written. Upstream writes each as
# `function NAME {` through a line holding only `}`; the text must end there
# and parse on its own, which catches a body that ends early or never ends.
exp_function_text() {
  local file="$1" fn="$2" text
  text=$(command awk -v fn="${fn}" '
    $0 == "function " fn " {" { p = 1 }
    p { print }
    p && $0 == "}" { exit }
  ' "${file}") || return 1
  if [[ -z "${text}" ]]; then
    print -u2 "ERROR: function ${fn} not found in ${file}"
    return 1
  fi
  if [[ "${text##*$'\n'}" != "}" ]]; then
    print -u2 "ERROR: function ${fn} in ${file} does not end with a line holding only }"
    return 1
  fi
  local -a heads=( ${(M)${(f)text}:#function *} )
  if [[ ${#heads[@]} -ne 1 ]]; then
    print -u2 "ERROR: function ${fn} in ${file} does not end before the next function"
    return 1
  fi
  if ! print -r -- "${text}" | zsh -n 2>/dev/null; then
    print -u2 "ERROR: function ${fn} in ${file} does not parse on its own"
    return 1
  fi
  print -r -- "${text}"
}

# exp_recipe_hash <packaging-dir> <library>
# Hashes how upstream's scripts build one library: build_<library> and its
# build_<library>_* hooks, the shared build_package and build_tarball,
# myinstall.sh, and the patches in <library>-patches/.
exp_recipe_hash() {
  setopt local_options pipe_fail
  local dir="$1" lib="$2" listing fn f part text="" hash
  local -a fns
  listing=$(command grep -E "^function build_${lib}(_[a-z_]+)? \\{\$" "${dir}/build.sh") || true
  fns=( ${(o)${${(f)listing}#function }% \{} )
  if (( ! ${fns[(Ie)build_${lib}]} )); then
    print -u2 "ERROR: build.sh has no function build_${lib}"
    return 1
  fi
  for fn in "${fns[@]}" build_package build_tarball; do
    part=$(exp_function_text "${dir}/build.sh" "${fn}") || return 1
    text+="== function ${fn}"$'\n'"${part}"$'\n'
  done
  part=$(command cat "${dir}/myinstall.sh") || return 1
  text+="== file myinstall.sh"$'\n'"${part}"$'\n'
  for f in "${dir}/${lib}-patches"/*.patch(N); do
    part=$(command cat "${f}") || return 1
    text+="== patch ${f:t}"$'\n'"${part}"$'\n'
  done
  hash=$(print -rn -- "${text}" | command shasum -a 256 | command cut -d' ' -f1) || hash=""
  if [[ -z "${hash}" ]]; then
    print -u2 "ERROR: cannot compute the recipe hash for ${lib}"
    return 1
  fi
  print -r -- "${hash}"
}

# exp_env_hash <packaging-dir>
# Hashes the values of EXP_KEY_VARS once config.sh and config.local.sh are
# read, in the order build.sh reads them, starting from an empty environment
# apart from HOME, PATH and MTX_EXP_ROOT — the environment library builds
# run in.
exp_env_hash() {
  setopt local_options pipe_fail
  local dir="$1" text hash
  local -a pass=()
  if [[ -n "${MTX_EXP_ROOT:-}" ]]; then pass+=("MTX_EXP_ROOT=${MTX_EXP_ROOT}"); fi
  text=$(command env -i HOME="${HOME}" PATH="${PATH}" "${pass[@]}" /bin/zsh -c '
    source "$1/config.sh" || exit 1
    if [[ -f "$1/config.local.sh" ]]; then source "$1/config.local.sh" || exit 1; fi
    shift
    for v in "$@"; do print -r -- "${v}=${(P)v}"; done
  ' exp-env "${dir}" "${EXP_KEY_VARS[@]}") || {
    print -u2 "ERROR: cannot read the build settings in ${dir}"
    return 1
  }
  hash=$(print -rn -- "${text}" | command shasum -a 256 | command cut -d' ' -f1) || hash=""
  if [[ -z "${hash}" ]]; then
    print -u2 "ERROR: cannot compute the build settings hash for ${dir}"
    return 1
  fi
  print -r -- "${hash}"
}

# exp_toolchain_id
# The compiler and SDK a build uses. EXP_TOOLCHAIN overrides it for tests.
exp_toolchain_id() {
  if [[ -n "${EXP_TOOLCHAIN:-}" ]]; then
    print -r -- "${EXP_TOOLCHAIN}"
    return 0
  fi
  local cc sdk
  cc=$(command clang --version | command head -1) || return 1
  sdk=$(command xcrun --show-sdk-version) || return 1
  if [[ -z "${cc}" || -z "${sdk}" ]]; then
    print -u2 "ERROR: cannot identify the toolchain"
    return 1
  fi
  print -r -- "${cc}; sdk ${sdk}"
}

# exp_spec_source <packaging-dir> <library>
# "<tarball> <sha256>" from the library's specs.sh entry.
exp_spec_source() {
  local dir="$1" lib="$2" out
  out=$(
    source "${dir}/specs.sh" || exit 1
    local var="spec_${lib}"
    local -a spec
    spec=( "${(@P)var}" )
    [[ -n "${spec[1]}" && -n "${spec[3]}" ]] || exit 1
    print -r -- "${spec[1]} ${spec[3]}"
  ) || {
    print -u2 "ERROR: specs.sh has no complete entry for ${lib}"
    return 1
  }
  print -r -- "${out}"
}

# exp_compute_keys <packaging-dir> <arch>
# Sets EXP_ORDER, and EXP_KEY, EXP_INPUT (the text the key hashes) and
# EXP_TARBALL for each library, and EXP_TOOLCHAIN_ID, which cache entries and
# build manifests record and no key includes.
exp_compute_keys() {
  setopt local_options pipe_fail
  local dir="$1" arch="$2" out lib src recipe env tool prev="" block hash
  EXP_ORDER=(); EXP_KEY=(); EXP_INPUT=(); EXP_TARBALL=()
  out=$(exp_build_order "${dir}") || return 1
  local -a order=( ${(f)out} )
  env=$(exp_env_hash "${dir}") || return 1
  tool=$(exp_toolchain_id) || return 1
  EXP_TOOLCHAIN_ID="${tool}"
  for lib in "${order[@]}"; do
    src=$(exp_spec_source "${dir}" "${lib}") || return 1
    recipe=$(exp_recipe_hash "${dir}" "${lib}") || return 1
    block="library=${lib}
source=${src}
recipe=${recipe}
env=${env}
arch=${arch}
previous=${prev}"
    EXP_INPUT[${lib}]="${block}"
    EXP_TARBALL[${lib}]="${src%% *}"
    hash=$(print -rn -- "${block}" | command shasum -a 256 | command cut -d' ' -f1) || hash=""
    if [[ -z "${hash}" ]]; then
      print -u2 "ERROR: cannot compute the key for ${lib}"
      return 1
    fi
    EXP_KEY[${lib}]="${hash}"
    prev="${hash}"
    EXP_ORDER+=("${lib}")
  done
}
