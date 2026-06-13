#!/bin/bash
# release.sh — cut a CalVer release of forticlient-macos-autoconnect.
#
# Versioning is CalVer with a per-day micro. The git tag is the ONLY version
# record (there is no package manifest to bump):
#   vYYYY.MM.DD       first release of a given day
#   vYYYY.MM.DD.N     N = 1, 2, … for each further release the same day
#
# What it does, in order:
#   1. sanity checks — clean working tree, on the main branch, HEAD already
#      pushed to origin, remote tags fetched;
#   2. runs the GUI-free safe test subset (osacompile + arg/Keychain checks);
#   3. computes the next CalVer tag from today's date and the existing tags;
#   4. creates an annotated tag whose body is the commit subjects since the
#      previous tag (the release notes);
#   5. pushes the tag and, when `gh` is available, creates a GitHub release.
#
# Usage:
#   ./release.sh                 cut and push a release for today
#   ./release.sh --dry-run       show the version and notes, change nothing
#   ./release.sh --no-gh         tag and push, but skip the GitHub release
#   ./release.sh --skip-tests    skip the safe-test gate (not recommended)
#   ./release.sh --allow-branch  allow releasing from a non-main branch
#   ./release.sh --help          this help
#
# Exit status: 0 on a successful release (or dry run), 1 on any failure.

set -euo pipefail

die() { printf 'release.sh: %s\n' "$1" >&2; exit 1; }
note() { printf '== %s\n' "$1"; }

usage() {
	cat <<'EOF'
release.sh — cut a CalVer release (tag vYYYY.MM.DD[.N]).

  ./release.sh                 cut and push a release for today
  ./release.sh --dry-run       show the version and notes, change nothing
  ./release.sh --no-gh         tag and push, but skip the GitHub release
  ./release.sh --skip-tests    skip the safe-test gate (not recommended)
  ./release.sh --allow-branch  allow releasing from a non-main branch
  ./release.sh --help          this help
EOF
}

DRY_RUN=0
DO_GH=1
RUN_TESTS=1
ALLOW_BRANCH=0
for arg in "$@"; do
	case "$arg" in
	--dry-run | -n) DRY_RUN=1 ;;
	--no-gh) DO_GH=0 ;;
	--skip-tests) RUN_TESTS=0 ;;
	--allow-branch) ALLOW_BRANCH=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "unknown argument: $arg (try --help)" ;;
	esac
done

toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$toplevel" || die "cannot cd to $toplevel"

# 1. sanity checks
branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$branch" != "main" ] && [ "$ALLOW_BRANCH" -eq 0 ]; then
	die "on branch '$branch', not 'main' — pass --allow-branch to override"
fi
if [ -n "$(git status --porcelain)" ]; then
	die "working tree is not clean — commit or stash changes before releasing"
fi
if ! git fetch --tags --quiet origin; then
	note "WARNING: could not fetch from origin; remote tags may be stale"
fi
# the tag must point at a commit that is already published
if [ "$ALLOW_BRANCH" -eq 0 ] && [ -n "$(git rev-list "origin/$branch..HEAD" 2>/dev/null)" ]; then
	die "HEAD is ahead of origin/$branch — push your commits first"
fi

# 2. safe-test gate
if [ "$RUN_TESTS" -eq 1 ]; then
	note "running safe tests (tests/manual-test.sh --safe-only)"
	if ! test_out="$(tests/manual-test.sh --safe-only 2>&1)"; then
		printf '%s\n' "$test_out" >&2
		die "safe tests failed — not releasing"
	fi
	note "safe tests passed"
fi

# 3. compute the next CalVer tag: vYYYY.MM.DD, or vYYYY.MM.DD.N for re-releases
base="v$(date +%Y.%m.%d)"
maxmicro=-1
while IFS= read -r t; do
	[ -n "$t" ] || continue
	if [ "$t" = "$base" ]; then
		micro=0
	else
		micro="${t#"$base".}"
	fi
	case "$micro" in
	'' | *[!0-9]*) continue ;; # not a plain numeric micro — ignore
	esac
	if [ "$micro" -gt "$maxmicro" ]; then maxmicro="$micro"; fi
done < <(git tag --list "$base" "$base.*")
if [ "$maxmicro" -lt 0 ]; then
	version="$base"
else
	version="$base.$((maxmicro + 1))"
fi
if git rev-parse -q --verify "refs/tags/$version" >/dev/null 2>&1; then
	die "tag $version already exists — aborting to avoid clobbering it"
fi

# 4. release notes — commit subjects since the previous tag. Restrict to CalVer
# tags (vYYYY.MM.DD[.N]) so a stray non-CalVer tag can't become the baseline.
prev_tag="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname | head -n1 || true)"
if [ -n "$prev_tag" ]; then
	range="$prev_tag..HEAD"
	notes_header="Changes since $prev_tag:"
else
	range="HEAD"
	notes_header="Initial release."
fi
notes="$(git log --no-merges --pretty=format:'- %s' "$range")"
[ -n "$notes" ] || notes="- (no new commits since ${prev_tag:-the start})"
body="$notes_header"$'\n\n'"$notes"

note "version:  $version"
note "previous: ${prev_tag:-<none>}"
printf '%s\n' "----- release notes -----" "$body" "-------------------------"

if [ "$DRY_RUN" -eq 1 ]; then
	note "dry run — no tag created, nothing pushed"
	exit 0
fi

# 5. tag, push, GitHub release
git tag -a "$version" -m "$version" -m "$body"
note "created annotated tag $version"
git push origin "$version"
note "pushed $version to origin"

if [ "$DO_GH" -eq 1 ] && command -v gh >/dev/null 2>&1; then
	if gh release create "$version" --title "$version" --notes "$body"; then
		note "created GitHub release $version"
	else
		die "tag pushed, but 'gh release create' failed — create the release manually"
	fi
elif [ "$DO_GH" -eq 1 ]; then
	note "gh not installed — skipped GitHub release (the tag is pushed)"
fi

note "done: $version"
