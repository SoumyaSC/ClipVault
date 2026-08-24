#!/bin/bash
# release.sh — cut a ClipVault release.
#
#   ./Scripts/release.sh patch          1.0.7 → 1.0.8
#   ./Scripts/release.sh minor          1.0.7 → 1.1.0
#   ./Scripts/release.sh major          1.0.7 → 2.0.0
#   ./Scripts/release.sh 1.2.3          explicit version
#   ./Scripts/release.sh patch --dry-run   print the plan, change nothing
#   ./Scripts/release.sh patch --publish   …then push, publish, refresh the tap
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
# Pushing and publishing only happen with --publish. Without it the script
# stops after the local tag and prints the exact commands.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/Scripts/version.sh"

die() { echo "✗ $*" >&2; exit 1; }

BUMP="${1:-}"
DRY_RUN=false
PUBLISH=false
shift || true
for flag in "$@"; do
    case "$flag" in
        --dry-run) DRY_RUN=true ;;
        --publish) PUBLISH=true ;;
        *) die "unknown flag: $flag" ;;
    esac
done
[ -n "$BUMP" ] || die "usage: $0 <patch|minor|major|X.Y.Z> [--dry-run] [--publish]"
$DRY_RUN && $PUBLISH && die "--dry-run and --publish are mutually exclusive"
if $PUBLISH; then
    command -v gh >/dev/null || die "--publish needs the GitHub CLI (gh)"
    gh auth status >/dev/null 2>&1 || die "--publish needs 'gh auth login'"
fi

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
python3 - "$NEXT" "$TODAY" "$(cv_repo_slug)" <<'PY'
import re, sys

version, today, slug = sys.argv[1], sys.argv[2], sys.argv[3]
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
              f'[Unreleased]: https://github.com/{slug}/compare/v{version}...HEAD',
              text, count=1, flags=re.M)
text = text.rstrip('\n') + f'\n[{version}]: https://github.com/{slug}/releases/tag/v{version}\n'
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
ARTIFACTS=()
while IFS= read -r file; do ARTIFACTS+=("$file"); done < <(ls dist/ClipVault-"$NEXT"*.zip dist/ClipVault-"$NEXT"*.dmg 2>/dev/null)
[ ${#ARTIFACTS[@]} -gt 0 ] || die "the build produced no artifacts in dist/"

echo ""
echo "✔ Released v$NEXT locally. Artifacts: ${ARTIFACTS[*]}"

if ! $PUBLISH; then
    echo "  To publish:"
    echo "    ./Scripts/release.sh $BUMP --publish   (next time)"
    echo "  or by hand:"
    echo "    git push origin HEAD --follow-tags"
    echo "    gh release create v$NEXT ${ARTIFACTS[*]} --title \"ClipVault $NEXT\" --notes-from-tag"
    exit 0
fi

# --- Publish ---------------------------------------------------------------

echo "▶︎ Pushing $NEXT"
git push -q origin HEAD --follow-tags

NOTES="$(mktemp)"
awk -v v="$NEXT" '
    $0 ~ "^## \\[" v "\\]" { flag = 1; next }
    flag && /^## / { exit }
    flag { print }
' CHANGELOG.md > "$NOTES"
[ -s "$NOTES" ] || die "no CHANGELOG section for $NEXT"

echo "▶︎ Publishing the GitHub release"
if gh release view "v$NEXT" >/dev/null 2>&1; then
    gh release upload "v$NEXT" "${ARTIFACTS[@]}" --clobber
else
    gh release create "v$NEXT" "${ARTIFACTS[@]}" \
        --title "ClipVault $NEXT" \
        --notes-file "$NOTES"
fi
rm -f "$NOTES"

# --- Homebrew tap ----------------------------------------------------------
#
# The checksum comes from the asset GitHub is actually serving, not from the
# local build: if an upload were ever truncated or replaced, a locally computed
# sha256 would happily certify the wrong bytes.

TAP_REPO="${TAP_REPO:-SoumyaSC/homebrew-tap}"
echo "▶︎ Refreshing the cask in $TAP_REPO"
DOWNLOAD_DIR="$(mktemp -d)"
if ! gh release download "v$NEXT" --repo "$(cv_repo_slug)" \
        --pattern "ClipVault-$NEXT.zip" --dir "$DOWNLOAD_DIR" >/dev/null 2>&1; then
    echo "  ✗ could not download the published zip — update the cask by hand" >&2
    rm -rf "$DOWNLOAD_DIR"
    exit 1
fi
SHA256="$(shasum -a 256 "$DOWNLOAD_DIR/ClipVault-$NEXT.zip" | awk '{print $1}')"
rm -rf "$DOWNLOAD_DIR"

TAP_DIR="$(mktemp -d)"
if gh repo clone "$TAP_REPO" "$TAP_DIR" -- --depth 1 -q 2>/dev/null; then
    mkdir -p "$TAP_DIR/Casks"
    cat > "$TAP_DIR/Casks/clipvault.rb" <<CASK
cask "clipvault" do
  version "$NEXT"
  sha256 "$SHA256"

  url "https://github.com/$(cv_repo_slug)/releases/download/v#{version}/ClipVault-#{version}.zip"
  name "ClipVault"
  desc "Menu bar clipboard manager for text and images"
  homepage "https://github.com/$(cv_repo_slug)"

  depends_on macos: :ventura

  app "ClipVault.app"

  zap trash: [
    "~/Library/Application Support/ClipVault",
    "~/Library/Preferences/app.clipvault.ClipVault.plist",
  ]
end
CASK
    git -C "$TAP_DIR" add -A
    if git -C "$TAP_DIR" commit -q -m "clipvault $NEXT"; then
        git -C "$TAP_DIR" push -q origin HEAD:main && echo "  ✓ cask updated to $NEXT"
    else
        echo "  · tap already at $NEXT"
    fi
    rm -rf "$TAP_DIR"
else
    echo "  ✗ could not clone $TAP_REPO — update the cask by hand" >&2
fi

echo ""
echo "✔ ClipVault $NEXT is published."
echo "    https://github.com/$(cv_repo_slug)/releases/tag/v$NEXT"
echo "    brew install --cask soumyasc/tap/clipvault"
