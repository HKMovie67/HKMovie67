#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source "$script_dir/android-release-rollback.sh"

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/hkmovie67-rollback-test.XXXXXX")
calls="$test_dir/calls"
trap 'rm -rf "$test_dir"' EXIT
ANDROID_RELEASE_ROLLBACK_RETRY_DELAY_SECONDS=0
mock_traffic_update_fail=no
mock_live_revision=
mock_release_edit_fail=no
mock_release_state=public

gcloud() {
  printf 'gcloud %s\n' "$*" >>"$calls"
  if [[ "$1 $2 $3" == 'run services update-traffic' ]]; then
    [[ "$mock_traffic_update_fail" != yes ]] || return 1
    mock_live_revision=$(printf '%s\n' "$*" | sed -n 's/.*--to-revisions \([^=]*\)=100.*/\1/p')
  elif [[ "$1 $2 $3" == 'run services describe' ]]; then
    printf '{"status":{"traffic":[{"percent":100,"revisionName":"%s"}]}}\n' "$mock_live_revision"
  fi
}
gh() {
  printf 'gh %s\n' "$*" >>"$calls"
  if [[ "$1 $2 $3" == 'release edit release-1' ]]; then
    [[ "$mock_release_edit_fail" != yes ]] || return 1
    mock_release_state=draft
  elif [[ "$1 $2 $3" == 'release edit release-2' || "$1 $2 $3" == 'release edit release-4' ]]; then
    [[ "$mock_release_edit_fail" != yes ]] || return 1
    mock_release_state=prerelease
  elif [[ "$1 $2 $3" == 'release edit release-5' ]]; then
    [[ "$*" == *'--draft=true'* && "$*" == *'--prerelease=true'* ]] || return 1
    mock_release_state=draft-prerelease
  elif [[ "$1 $2" == 'release view' ]]; then
    if [[ "$mock_release_state" == draft ]]; then
      printf '{"isDraft":true,"isPrerelease":false}\n'
    elif [[ "$mock_release_state" == prerelease ]]; then
      printf '{"isDraft":false,"isPrerelease":true}\n'
    elif [[ "$mock_release_state" == draft-prerelease ]]; then
      printf '{"isDraft":true,"isPrerelease":true}\n'
    else
      printf '{"isDraft":false,"isPrerelease":false}\n'
    fi
  fi
}

restore_android_release_state 65 no yes true false gateway project region revision-1 release-1 owner/repo
grep -F 'gh release edit release-1 --repo owner/repo --draft=true' "$calls" >/dev/null
if grep -F 'gcloud ' "$calls" >/dev/null; then
  echo "Traffic rollback ran before promotion." >&2
  exit 1
fi

: >"$calls"
mock_release_state=public
restore_android_release_state 1 yes yes false true gateway project region revision-2 release-2 owner/repo
grep -F 'gcloud run services update-traffic gateway --project project --region region --to-revisions revision-2=100 --quiet' "$calls" >/dev/null
grep -F 'gh release edit release-2 --repo owner/repo --prerelease=true' "$calls" >/dev/null

: >"$calls"
mock_release_state=public
mock_traffic_update_fail=yes
if restore_android_release_state 1 yes yes false true gateway project region revision-4 release-4 owner/repo; then
  echo "Rollback unexpectedly passed when traffic restoration failed." >&2
  exit 1
fi
[[ $(grep -c 'gcloud run services update-traffic' "$calls") -eq 3 ]]
grep -F 'gh release edit release-4 --repo owner/repo --prerelease=true' "$calls" >/dev/null

: >"$calls"
mock_release_state=public
mock_traffic_update_fail=no
restore_android_release_state 1 no yes true true gateway project region revision-5 release-5 owner/repo
grep -F 'gh release edit release-5 --repo owner/repo --draft=true --prerelease=true' "$calls" >/dev/null

: >"$calls"
mock_traffic_update_fail=no
restore_android_release_state 0 yes yes true false gateway project region revision-3 release-3 owner/repo
[[ ! -s "$calls" ]]

echo "Android release rollback tests passed."
