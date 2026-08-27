#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source "$script_dir/android-release-rollback.sh"

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/hkmovie67-rollback-test.XXXXXX")
calls="$test_dir/calls"
trap 'rm -rf "$test_dir"' EXIT

gcloud() { printf 'gcloud %s\n' "$*" >>"$calls"; }
gh() { printf 'gh %s\n' "$*" >>"$calls"; }

restore_android_release_state 65 no yes true false gateway project region revision-1 release-1 owner/repo
grep -F 'gh release edit release-1 --repo owner/repo --draft=true' "$calls" >/dev/null
if grep -F 'gcloud ' "$calls" >/dev/null; then
  echo "Traffic rollback ran before promotion." >&2
  exit 1
fi

: >"$calls"
restore_android_release_state 1 yes yes false true gateway project region revision-2 release-2 owner/repo
grep -F 'gcloud run services update-traffic gateway --project project --region region --to-revisions revision-2=100 --quiet' "$calls" >/dev/null
grep -F 'gh release edit release-2 --repo owner/repo --prerelease=true' "$calls" >/dev/null

: >"$calls"
restore_android_release_state 0 yes yes true false gateway project region revision-3 release-3 owner/repo
[[ ! -s "$calls" ]]

echo "Android release rollback tests passed."
