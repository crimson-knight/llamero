#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GRANT_CHECKOUT="/Users/crimsonknight/open_source_coding_projects/amber_framework_libraries/grant-integration"
AMBER_CHECKOUT="/Users/crimsonknight/open_source_coding_projects/amber"
GUIDE_CHECKOUT="/Users/crimsonknight/open_source_coding_projects/amberframework.org/.claude/worktrees/docs-grant-multitenancy"
GRANT_COMMIT="c6b5e72c1e2663fe6b5cb6794a5beddd0c34f7a3"
AMBER_COMMIT="f2a1490fc7d25310a8d08cca8fe15434ec08169f"
GUIDE_COMMIT="fd988199a97a360f96b0cb06bac36c28085958c7"
GRANT_SOURCE_DIR="$ROOT/.crystal-cache/grant-c6b5e72"
AMBER_SOURCE_DIR="$ROOT/.crystal-cache/amber-f2a1490"
GUIDE_SOURCE_DIR="$ROOT/.crystal-cache/guide-fd988199"
GRANT_STAGING_DIR="$ROOT/.crystal-cache/grant-c6b5e72-staging-$$"

mkdir -p "$ROOT/.crystal-cache"
python3 "$ROOT/scripts/verify_amber_grant_toolchain.py" --prepare-only

ACTUAL_COMMIT="$(git -C "$GRANT_CHECKOUT" rev-parse "$GRANT_COMMIT^{commit}")"
if [[ "$ACTUAL_COMMIT" != "$GRANT_COMMIT" ]]; then
  printf 'Pinned Grant commit mismatch: %s\n' "$ACTUAL_COMMIT" >&2
  exit 1
fi

(cd "$GRANT_CHECKOUT" && shards-alpha install --frozen --skip-postinstall --skip-ai-docs --skip-ai-assistant)

if [[ -f "$GRANT_SOURCE_DIR/.grant-source-commit" ]]; then
  if [[ "$(cat "$GRANT_SOURCE_DIR/.grant-source-commit")" != "$GRANT_COMMIT" ]]; then
    printf 'Pinned Grant source marker mismatch at %s\n' "$GRANT_SOURCE_DIR" >&2
    exit 1
  fi
  printf 'Pinned Grant source already prepared at %s\n' "$GRANT_SOURCE_DIR"
else
  if [[ -e "$GRANT_SOURCE_DIR" || -e "$GRANT_STAGING_DIR" ]]; then
    printf 'Refusing to replace an unmarked Grant source directory.\n' >&2
    exit 1
  fi
  mkdir -p "$GRANT_STAGING_DIR"
  git -C "$GRANT_CHECKOUT" archive "$GRANT_COMMIT" | tar -xf - -C "$GRANT_STAGING_DIR"
  mkdir -p "$GRANT_STAGING_DIR/lib"
  for DEPENDENCY in db pg sqlite3 mysql; do
    ln -s "$GRANT_CHECKOUT/lib/$DEPENDENCY" "$GRANT_STAGING_DIR/lib/$DEPENDENCY"
  done
  printf '%s\n' "$GRANT_COMMIT" > "$GRANT_STAGING_DIR/.grant-source-commit"
  mv "$GRANT_STAGING_DIR" "$GRANT_SOURCE_DIR"
  printf 'Prepared Grant %s at %s\n' "$GRANT_COMMIT" "$GRANT_SOURCE_DIR"
fi

prepare_archive() {
  local repository="$1"
  local commit="$2"
  local destination="$3"
  local marker_name="$4"
  local staging="$ROOT/.crystal-cache/$(basename "$destination")-staging-$$"
  local actual_commit

  actual_commit="$(git -C "$repository" rev-parse "$commit^{commit}")"
  if [[ "$actual_commit" != "$commit" ]]; then
    printf 'Pinned source commit mismatch for %s: %s\n' "$repository" "$actual_commit" >&2
    exit 1
  fi
  if [[ -f "$destination/$marker_name" ]]; then
    if [[ "$(cat "$destination/$marker_name")" == "$commit" ]]; then
      printf 'Pinned source already prepared at %s\n' "$destination"
      return
    fi
    printf 'Pinned source marker mismatch at %s\n' "$destination" >&2
    exit 1
  fi
  if [[ -e "$destination" || -e "$staging" ]]; then
    printf 'Refusing to replace an unmarked source directory: %s\n' "$destination" >&2
    exit 1
  fi
  mkdir -p "$staging"
  git -C "$repository" archive "$commit" | tar -xf - -C "$staging"
  printf '%s\n' "$commit" > "$staging/$marker_name"
  mv "$staging" "$destination"
  printf 'Prepared source %s at %s\n' "$commit" "$destination"
}

prepare_archive "$AMBER_CHECKOUT" "$AMBER_COMMIT" "$AMBER_SOURCE_DIR" ".amber-source-commit"
prepare_archive "$GUIDE_CHECKOUT" "$GUIDE_COMMIT" "$GUIDE_SOURCE_DIR" ".guide-source-commit"

python3 "$ROOT/scripts/verify_amber_grant_toolchain.py"
