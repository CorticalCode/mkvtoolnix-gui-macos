#!/bin/bash
# Backfill SHA256 checksums for existing tarballs and DMGs that don't have one.
# Idempotent: skips any file that already has a matching .sha256.
#
# Scans:
#   ~/opt/proven/{arm,intel}          (the canonical local proven cache)
#   ~/opt/proven-experimental/{arm,intel}
#   <repo>/build                      (internal dev DMGs)
#   <repo>/release                    (release-ready DMGs)
#
# Does NOT scan <repo>/proven/ — those files are LFS-managed and their
# checksums are emitted by build-local.sh during --promote.
#
# Usage: tools/backfill-sha256.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Both roots come from the config overlays, the single source of truth for
# where each tree lives. Each is evaluated in its own subshell: the overlays
# derive their paths from MTX_ROOT with a ${MTX_ROOT:-default} form, so
# sourcing them one after another in the same shell would leave the first
# file's root in place and silently resolve the second tree to it.
_target_from() {
  [ -f "$1" ] || { printf '%s' "$HOME/opt"; return; }
  # shellcheck disable=SC1090
  ( . "$1" >/dev/null 2>&1; printf '%s' "$TARGET" )
}
_rel_target="$(_target_from "$SCRIPT_DIR/config/config.local.sh")"
_exp_target="$(_target_from "$SCRIPT_DIR/config/config.exp.local.sh")"

SCAN_DIRS=(
  "$_rel_target/proven/arm"
  "$_rel_target/proven/intel"
  "$_exp_target/proven-experimental/arm"
  "$_exp_target/proven-experimental/intel"
  "$SCRIPT_DIR/build"
  "$SCRIPT_DIR/release"
)

GLOBS=("*.tar.gz" "*.dmg")

generated=0
skipped=0
scanned=0

for dir in "${SCAN_DIRS[@]}"; do
  [[ -d "$dir" ]] || continue
  echo "Scanning $dir ..."
  for pattern in "${GLOBS[@]}"; do
    for f in "$dir"/$pattern; do
      [[ -f "$f" ]] || continue
      scanned=$((scanned + 1))
      if [[ -f "$f.sha256" ]]; then
        skipped=$((skipped + 1))
        continue
      fi
      filename=$(basename "$f")
      (cd "$(dirname "$f")" && shasum -a 256 "$filename" > "$filename.sha256")
      echo "  generated: $(basename "$f").sha256"
      generated=$((generated + 1))
    done
  done
done

echo ""
echo "Backfill complete."
echo "  Scanned:   $scanned"
echo "  Generated: $generated"
echo "  Skipped:   $skipped (already had .sha256)"
