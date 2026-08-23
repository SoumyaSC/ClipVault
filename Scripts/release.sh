#!/bin/bash
# release.sh — cut a ClipVault release.
#
#   ./Scripts/release.sh patch          1.0.7 → 1.0.8
#   ./Scripts/release.sh minor          1.0.7 → 1.1.0
#   ./Scripts/release.sh major          1.0.7 → 2.0.0
#   ./Scripts/release.sh 1.2.3          explicit version
#   ./Scripts/release.sh patch --dry-run   print the plan, change nothing
#
# What it does, in order — it stops at the first failure and, once it has
# started writing, rolls the working tree back:
#
#   1. refuses to run on a dirty tree or without an [Unreleased] entry
#   2. writes VERSION and promotes [Unreleased] to the new version in CHANGELOG
#   3. commits "Release vX.Y.Z"
#   4. runs the full build (tests → universal binary → bundle → archive) — after
#      the commit, so the build number matches what CI stamps from the tag
#   5. creates an annotated tag on the verified commit
#
# Pushing and publishing stay manual — the script prints the exact commands.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/Scripts/version.sh"

die() { echo "✗ $*" >&2; exit 1; }

BUMP="${1:-}"
DRY_RUN=false
[ "${2:-}" = "--dry-run" ] && DRY_RUN=true
[ -n "$BUMP" ] || die "usage: $0 <patch|minor|major|X.Y.Z> [--dry-run]"

CURRENT="$(cv_version)"
cv_validate_semver "$CURRENT"
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"

case "$BUMP" in
    major) NEXT="$((MAJOR + 1)).0.0" ;;
    minor) NEXT="$MAJOR.$((MINOR + 1)).0" ;;
    patch) NEXT="$MAJOR.$MINOR.$((PATCH + 1))" ;;
    *)     NEXT="$BUMP"; cv_validate_semver "$NEXT" ;;
esac

# --- Preflight -------------------------------------------------------------

git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository — run 'git init' first"
cv_is_dirty && die "working tree is dirty; commit or stash before releasing"
git rev-parse "v$NEXT" >/dev/null 2>&1 && die "tag v$NEXT already exists"

[ "$(printf '%s\n%s\n' "$CURRENT" "$NEXT" | sort -V | tail -1)" = "$NEXT" ] \
    || die "$NEXT is not newer than the current version $CURRENT"

grep -q '^## \[Unreleased\]' CHANGELOG.md || die "CHANGELOG.md has no [Unreleased] section"
UNRELEASED_BODY="$(awk '/^## \[Unreleased\]/{flag=1; next} /^## /{flag=0} flag' CHANGELOG.md \
                   | grep -v '^\s*$' | grep -v '^_Nothing yet\._$' || true)"
[ -n "$UNRELEASED_BODY" ] || die "nothing under [Unreleased] in CHANGELOG.md — describe the release first"

echo "▶︎ Release plan"
echo "    version   $CURRENT → $NEXT"
echo "    build     $(cv_build_number) → $(( $(cv_build_number) + 1 )) (commit count, incl. the release commit)"
echo "    tag       v$NEXT"
echo "    changelog $(echo "$UNRELEASED_BODY" | wc -l | tr -d ' ') line(s) promoted from [Unreleased]"

if $DRY_RUN; then
    echo "✔ dry run — nothing written"
    exit 0
fi

# --- Write -----------------------------------------------------------------

committed=false

rollback() {
    echo "✗ release failed — rolling back" >&2
    if $committed; then
        git reset --hard HEAD~1 >/dev/null 2>&1 || true
    else
        git checkout -- VERSION CHANGELOG.md 2>/dev/null || true
    fi
}
trap rollback ERR

echo "$NEXT" > VERSION

TODAY="$(date +%Y-%m-%d)"
python3 - "$NEXT" "$TODAY" <<'PY'
import re, sys

version, today = sys.argv[1], sys.argv[2]
lines = open('CHANGELOG.md').read().split('\n')

# Everything between "## [Unreleased]" and the next "## " heading is this
# release's body; a fresh, empty [Unreleased] takes its place.
start = next(i for i, l in enumerate(lines) if l.startswith('## [Unreleased]'))
end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith('## ')), len(lines))
body = [l for l in lines[start + 1:end] if l.strip() != '_Nothing yet._']
while body and not body[0].strip():
    body.pop(0)
while body and not body[-1].strip():
    body.pop()

released = ['## [Unreleased]', '', '_Nothing yet._', '', f'## [{version}] \u2014 {today}', ''] + body + ['']
text = '\n'.join(lines[:start] + released + lines[end:])

text = re.sub(r'^\[Unreleased\]: .*$',
              f'[Unreleased]: https://github.com/OWNER/ClipVault/compare/v{version}...HEAD',
              text, count=1, flags=re.M)
text = text.rstrip('\n') + f'\n[{version}]: https://github.com/OWNER/ClipVault/releases/tag/v{version}\n'
open('CHANGELOG.md', 'w').write(text)
PY

# Commit *before* building: CFBundleVersion is the commit count and CI builds
# from the tag, so building first would ship a bundle one build behind CI's.
git add VERSION CHANGELOG.md
git commit -q -m "Release v$NEXT"
committed=true

echo "▶︎ Building $NEXT"
./Scripts/build_app.sh

git tag -a "v$NEXT" -m "ClipVault $NEXT"
trap - ERR

echo ""
echo "✔ Released v$NEXT locally. To publish:"
echo "    git push origin HEAD --follow-tags"
echo "    gh release create v$NEXT dist/ClipVault-$NEXT*.zip dist/ClipVault-$NEXT*.dmg \\"
echo "        --title \"ClipVault $NEXT\" --notes-from-tag"
echo ""
echo "  (pushing the tag also triggers .github/workflows/release.yml, which builds"
echo "   and attaches the artifacts on its own — publish by hand only if CI is off.)"
