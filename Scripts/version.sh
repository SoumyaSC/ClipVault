#!/bin/bash
# version.sh — single source of truth for ClipVault's version identity.
#
# Sourced by build_app.sh and release.sh; also runnable directly to inspect
# what the next build would stamp:
#
#   ./Scripts/version.sh
#
# Version comes from the VERSION file (semver, hand-edited only via
# release.sh). The build number is the git commit count, which is monotonic
# by construction — macOS compares CFBundleVersion when deciding whether a
# copy is newer, so it must never go backwards. Outside a git checkout
# (tarball builds) it falls back to 0.

set -euo pipefail

cv_root() { cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd; }

cv_version() {
    local file="$(cv_root)/VERSION"
    [ -f "$file" ] || { echo "VERSION file missing at $file" >&2; return 1; }
    tr -d '[:space:]' < "$file"
}

cv_validate_semver() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo "Not a semver MAJOR.MINOR.PATCH version: '$1'" >&2
        return 1
    }
}

cv_build_number() {
    git -C "$(cv_root)" rev-list --count HEAD 2>/dev/null || echo 0
}

cv_commit() {
    git -C "$(cv_root)" rev-parse --short=9 HEAD 2>/dev/null || echo "unknown"
}

cv_is_dirty() {
    [ -n "$(git -C "$(cv_root)" status --porcelain 2>/dev/null)" ]
}

# Direct invocation prints the identity this checkout would build.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    v="$(cv_version)"
    cv_validate_semver "$v"
    printf 'version      %s\n' "$v"
    printf 'build        %s\n' "$(cv_build_number)"
    printf 'commit       %s%s\n' "$(cv_commit)" "$(cv_is_dirty && echo ' (dirty)')"
    printf 'marketing    ClipVault %s (%s)\n' "$v" "$(cv_build_number)"
fi
