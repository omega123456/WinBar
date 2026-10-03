#!/bin/bash
# Bump the version in Info.plist, verify the build, then commit, tag vX.Y.Z and push.
# The pushed tag triggers .github/workflows/release.yml. Run it yourself (it prompts and pushes).
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST=Info.plist
BODY=.github/release-body.md
DEFAULT_BODY="See the attached WinBar zip. Installed copies update themselves."
pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }
die() { echo "[release] $*" >&2; exit 1; }

git remote get-url origin >/dev/null 2>&1 || die 'Missing git remote "origin".'
[[ -z $(git status --porcelain) ]] || die "Working tree is not clean."

current=$(pb "Print :CFBundleShortVersionString")
[[ $current =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "Current version \"$current\" is not MAJOR.MINOR.PATCH."
major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]}

echo "Current version: $current"
echo
echo "How much to bump?"
echo "  1 = major (X.0.0)"
echo "  2 = minor (0.X.0)"
echo "  3 = patch (0.0.X)"
echo "  4 = set a specific version (MAJOR.MINOR.PATCH)"
echo
read -r -p "Choice [1-4]: " choice
case $choice in
    1) next="$((major + 1)).0.0" ;;
    2) next="$major.$((minor + 1)).0" ;;
    3) next="$major.$minor.$((patch + 1))" ;;
    4) read -r -p "New version (MAJOR.MINOR.PATCH): " next
       [[ $next =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Not MAJOR.MINOR.PATCH." ;;
    *) die "Enter 1, 2, 3, or 4." ;;
esac
[[ $next != "$current" ]] || die "New version equals the current one."
tag="v$next"
! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || die "Git tag \"$tag\" already exists."

echo
echo "Release notes for the GitHub release."
echo "Press Enter once to use the default message, or enter multiple lines and finish with an empty line."
echo
echo "Default:"
echo "  $DEFAULT_BODY"
echo
notes=""
while true; do
    if [[ -z $notes ]]; then read -r -p "Notes (Enter = default): " line; else read -r -p "Notes (empty line ends): " line; fi
    if [[ -z $notes && -z ${line// } ]]; then notes=$DEFAULT_BODY; break; fi
    if [[ -n $notes && -z $line ]]; then break; fi
    notes+="${notes:+$'\n'}$line"
done

# Snapshot, write, verify; restore on failure.
plist_backup=$(mktemp); cp "$PLIST" "$plist_backup"
body_backup=""; if [[ -f $BODY ]]; then body_backup=$(mktemp); cp "$BODY" "$body_backup"; fi
restore() {
    cp "$plist_backup" "$PLIST"
    if [[ -n $body_backup ]]; then cp "$body_backup" "$BODY"; else rm -f "$BODY"; fi
}
trap 'restore; die "Build or self-test failed; files restored."' ERR

pb "Set :CFBundleShortVersionString $next"
pb "Set :CFBundleVersion $next"
mkdir -p "$(dirname "$BODY")"
printf '%s\n' "$notes" > "$BODY"

swift build -c release
swift run WinBar --self-test
trap - ERR

git add "$PLIST" "$BODY"
git commit -m "chore: bump version to $next"
git tag "$tag"
git push
git push origin "$tag"
echo "[release] Pushed $tag; the Release workflow builds and publishes it."
