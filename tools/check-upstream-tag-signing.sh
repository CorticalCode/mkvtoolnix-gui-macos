#!/bin/zsh
# tools/check-upstream-tag-signing.sh
#
# Probes whether the upstream MKVToolNix codeberg repo signs its release tags
# with the pinned mbunkus key. Run before deploying git verify-tag in
# build-local.sh — if upstream doesn't sign tags, that block will fail closed
# on every build.
#
# Also useful periodically: if mbunkus rotates his signing key (caught by
# verify-mbunkus-key.yml), re-running this confirms the rotated key is still
# being used to sign tags before build-local.sh starts trusting it.
#
# Usage:
#   ./tools/check-upstream-tag-signing.sh                     # newest 3 release tags
#   ./tools/check-upstream-tag-signing.sh release-99.0 ...    # a specific set
#
# Reads from the same directory the script lives in:
#   - mbunkus-pubkey.asc
#   - mbunkus-fingerprint.txt
#
# Exit codes:
#   0 — all checked tags are signed by the pinned key
#   1 — one or more tags unsigned, or signed by a different key
#   2 — script error (clone failed, missing trust artifacts, etc.)

set -e
setopt NULL_GLOB
unalias -a 2>/dev/null || true

SCRIPT_DIR=${0:a:h}
UPSTREAM_URL="https://codeberg.org/mbunkus/mkvtoolnix.git"
PUBKEY="${SCRIPT_DIR}/mbunkus-pubkey.asc"
PINNED_FP_FILE="${SCRIPT_DIR}/mbunkus-fingerprint.txt"

# Tags to check. With no arguments the newest few are read from the clone
# below, so no release number lives in this file; pass tags explicitly to
# check a specific set. Three recent tags are a reasonable sample.
TAG_SAMPLE_COUNT=3
TAGS_TO_CHECK=("$@")

# --- Preconditions ---
if [[ ! -f "${PUBKEY}" ]] || [[ ! -f "${PINNED_FP_FILE}" ]]; then
    echo "ERROR: Missing trust artifacts in ${SCRIPT_DIR}" >&2
    echo "  Expected: ${PUBKEY}" >&2
    echo "  Expected: ${PINNED_FP_FILE}" >&2
    echo "" >&2
    echo "  This script must live in the tools/ directory alongside the" >&2
    echo "  pinned mbunkus key and fingerprint files." >&2
    exit 2
fi

PINNED_FP=$(tr -d '[:space:]' < "${PINNED_FP_FILE}")
if [[ ! "${PINNED_FP}" =~ ^[0-9A-F]{40}$ ]]; then
    echo "ERROR: Pinned fingerprint malformed: ${PINNED_FP}" >&2
    exit 2
fi
echo "Pinned mbunkus fingerprint: ${PINNED_FP}"
echo ""

# --- Set up an isolated GPG homedir ---
GPG_HOME=$(mktemp -d)
CLONE_PARENT=$(mktemp -d)
# shellcheck disable=SC2064
trap "command rm -rf '${GPG_HOME}' '${CLONE_PARENT}'" EXIT INT TERM

if ! gpg_log=$(gpg --homedir "${GPG_HOME}" --batch --quiet \
        --import "${PUBKEY}" 2>&1); then
    echo "ERROR: Could not import ${PUBKEY:t} into a temporary keyring" >&2
    echo "${gpg_log}" | sed 's/^/  /' >&2
    exit 2
fi

# --- Clone upstream (shallow, all tags) ---
CLONE_DIR="${CLONE_PARENT}/mkvtoolnix-tag-check"
echo "==> Cloning ${UPSTREAM_URL} (shallow, with tags)..."
if ! clone_log=$(git clone --filter=blob:none --no-checkout \
        "${UPSTREAM_URL}" "${CLONE_DIR}" 2>&1); then
    echo "ERROR: Clone failed" >&2
    echo "${clone_log}" | tail -5 | sed 's/^/  /' >&2
    exit 2
fi

# Read the sample from the clone that was just made, rather than a second
# network call. ${(f)...} splits on newlines only; a bare $(...) would split
# on IFS.
if [[ ${#TAGS_TO_CHECK[@]} -eq 0 ]]; then
    TAGS_TO_CHECK=(${(f)"$(git -C "${CLONE_DIR}" tag --list 'release-*' \
        --sort=-v:refname | head -n ${TAG_SAMPLE_COUNT})"})
    if [[ ${#TAGS_TO_CHECK[@]} -eq 0 ]]; then
        echo "ERROR: No release-* tags found in ${UPSTREAM_URL}" >&2
        exit 2
    fi
    echo "==> Newest ${#TAGS_TO_CHECK[@]} release tags: ${TAGS_TO_CHECK[*]}"
fi

# --- Check each tag ---
all_ok=true
any_unsigned=false
any_wrong_key=false

for tag in "${TAGS_TO_CHECK[@]}"; do
    echo ""
    echo "=== ${tag} ==="

    # Step 1: Does the tag exist?
    if ! git -C "${CLONE_DIR}" rev-parse --verify "refs/tags/${tag}" >/dev/null 2>&1; then
        echo "  SKIP: Tag does not exist in upstream"
        continue
    fi

    # Step 2: Is it an annotated tag (a prerequisite for being signed)?
    tag_type=$(git -C "${CLONE_DIR}" cat-file -t "refs/tags/${tag}" 2>/dev/null)
    if [[ "${tag_type}" != "tag" ]]; then
        echo "  UNSIGNED: Lightweight tag (not annotated, cannot be signed)"
        any_unsigned=true
        all_ok=false
        continue
    fi

    # Step 3: Does the tag have a GPG signature block?
    if ! git -C "${CLONE_DIR}" cat-file tag "${tag}" | grep -q "BEGIN PGP SIGNATURE"; then
        echo "  UNSIGNED: Annotated tag with no GPG signature"
        any_unsigned=true
        all_ok=false
        continue
    fi

    # Step 4: Does the signature verify against the pinned key?
    verify_output=$(GNUPGHOME="${GPG_HOME}" \
        git -C "${CLONE_DIR}" verify-tag --raw "${tag}" 2>&1 || true)

    if echo "${verify_output}" | grep -q "GOODSIG"; then
        # Step 5: Does the signing key match the pinned fingerprint?
        # VALIDSIG line includes the full primary key fingerprint as field 12.
        signing_fp=$(echo "${verify_output}" | awk '/VALIDSIG/ {print $12; exit}')
        if [[ -z "${signing_fp}" ]]; then
            # Fall back to GOODSIG keyid (16-char), match against tail of pinned
            signing_keyid=$(echo "${verify_output}" | awk '/GOODSIG/ {print $3; exit}')
            if [[ "${PINNED_FP}" == *"${signing_keyid}" ]]; then
                echo "  OK: Signed by pinned key (matched on keyid ${signing_keyid})"
            else
                echo "  WRONG KEY: Signed by ${signing_keyid}, pinned is ${PINNED_FP:24:16}"
                any_wrong_key=true
                all_ok=false
            fi
        elif [[ "${signing_fp}" == "${PINNED_FP}" ]]; then
            echo "  OK: Signed by pinned key (full fingerprint match)"
        else
            echo "  WRONG KEY: Signed by ${signing_fp}, pinned is ${PINNED_FP}"
            any_wrong_key=true
            all_ok=false
        fi
    else
        echo "  VERIFICATION FAILED: gpg did not return GOODSIG"
        echo "  --- gpg output ---"
        echo "${verify_output}" | sed 's/^/  /'
        any_wrong_key=true
        all_ok=false
    fi
done

# --- Summary and recommendation ---
echo ""
echo "================================================================"
if [[ "${all_ok}" == true ]]; then
    echo "RESULT: All checked tags are signed by the pinned mbunkus key."
    echo ""
    echo "Recommendation: Safe to deploy git verify-tag in build-local.sh."
    exit 0
elif [[ "${any_wrong_key}" == true ]]; then
    echo "RESULT: One or more tags signed by an UNEXPECTED key."
    echo ""
    echo "This is unusual and warrants investigation before deploying anything."
    echo "Possible causes: subkey rotation, intermediate signing key, or"
    echo "                 upstream signing-key change not yet reflected in tools/."
    exit 1
else
    echo "RESULT: One or more tags are NOT GPG-signed."
    echo ""
    echo "Recommendation: Do NOT deploy git verify-tag — it would fail closed"
    echo "                on unsigned tags. Pursue the alternative: extract"
    echo "                packaging/macos/ from the verified source tarball"
    echo "                and use that as the build script source rather than"
    echo "                the codeberg clone."
    exit 1
fi
