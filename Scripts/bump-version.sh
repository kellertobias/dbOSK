#!/bin/bash
# Computes the next semantic version from commit messages and writes it to the
# VERSION file, printing the new version to stdout. Used by the Forgejo release
# workflow (.forgejo/workflows/release.yml), but safe to run locally.
#
# Usage:
#   Scripts/bump-version.sh              # bump VERSION and print the new value
#   Scripts/bump-version.sh --dry-run    # print what the next version would be
#
# Range: commits since the most recent tag (vX.Y.Z), or the whole history when
# the repo is untagged.
#
# Bump rules (Conventional-Commits-ish, tuned for this repo):
#   major  any commit whose type ends with "!" (e.g. feat!:) or whose body
#          contains a "BREAKING CHANGE" footer
#   patch  every commit in range is a "fix" commit (fix: / fix(scope):)
#   minor  otherwise -- i.e. any "regular" (non-fix) commit, including plain
#          unprefixed subjects. This is the repo default.
#
# If there are no commits in range, the current version is printed unchanged.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION_FILE="VERSION"
dry_run=0
[[ "${1:-}" == "--dry-run" ]] && dry_run=1

current="$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || echo "0.0.0")"
[[ -n "$current" ]] || current="0.0.0"

last_tag="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [[ -n "$last_tag" ]]; then
    range="${last_tag}..HEAD"
else
    range="HEAD"
fi

# Regexes live in variables: bash only parses parens inside [[ =~ ]] correctly
# when the pattern is unquoted *and* comes from a variable. [(]/[)] match
# literal parens portably (ERE \( is unreliable across bash builds).
major_re="^[a-zA-Z]+([(][^)]*[)])?!"   # type with a "!" -> breaking change
fix_re="^[Ff]ix([(][^)]*[)])?:"         # fix: / fix(scope): -> patch

major=0 minor=0 patch=0 count=0
while IFS= read -r subj; do
    [[ -z "$subj" ]] && continue
    count=$((count + 1))
    if [[ "$subj" =~ $major_re ]]; then
        major=1
    elif [[ "$subj" =~ $fix_re ]]; then
        patch=1
    else
        minor=1
    fi
done < <(git log --format='%s' "$range" 2>/dev/null)

# A "BREAKING CHANGE:" footer anywhere in the range also forces a major bump.
if git log --format='%b' "$range" 2>/dev/null | grep -q 'BREAKING CHANGE'; then
    major=1
fi

if [[ "$count" -eq 0 ]]; then
    bump="none"
elif [[ "$major" -eq 1 ]]; then
    bump="major"
elif [[ "$minor" -eq 1 ]]; then
    bump="minor"
else
    bump="patch"
fi

IFS=. read -r MA MI PA <<< "$current"
MA="${MA:-0}" MI="${MI:-0}" PA="${PA:-0}"
case "$bump" in
    major) MA=$((MA + 1)); MI=0; PA=0 ;;
    minor) MI=$((MI + 1)); PA=0 ;;
    patch) PA=$((PA + 1)) ;;
    none)  echo "$current"; exit 0 ;;
esac
new="${MA}.${MI}.${PA}"

if [[ "$dry_run" -eq 0 ]]; then
    printf '%s\n' "$new" > "$VERSION_FILE"
fi
printf '%s\n' "$new"
