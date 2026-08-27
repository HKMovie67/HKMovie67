#!/usr/bin/env bash

restore_android_release_state() {
  local status=$1
  local promoted=$2
  local release_visibility_changed=$3
  local release_was_draft=$4
  local release_was_prerelease=$5
  local gateway_service=$6
  local project=$7
  local region=$8
  local previous_revision=$9
  local release_tag=${10}
  local repo=${11}
  local retry_delay=${ANDROID_RELEASE_ROLLBACK_RETRY_DELAY_SECONDS:-2}
  local rollback_failed=no
  local attempt expected_filter restored
  local -a restore_flags=()

  [[ "$status" -ne 0 ]] || return 0
  if [[ "$promoted" == yes ]]; then
    echo "Release verification failed; restoring gateway traffic to $previous_revision." >&2
    restored=no
    for attempt in 1 2 3; do
      if gcloud run services update-traffic "$gateway_service" --project "$project" --region "$region" \
        --to-revisions "$previous_revision=100" --quiet \
        && gcloud run services describe "$gateway_service" --project "$project" --region "$region" --format=json \
          | jq -e --arg revision "$previous_revision" \
            'any(.status.traffic[]; (.percent // 0) == 100 and .revisionName == $revision)' >/dev/null; then
        restored=yes
        break
      fi
      sleep "$retry_delay"
    done
    if [[ "$restored" != yes ]]; then
      echo "CRITICAL: unable to verify gateway traffic rollback." >&2
      rollback_failed=yes
    fi
  fi
  if [[ "$release_visibility_changed" == yes ]]; then
    echo "Release verification failed; restoring prior GitHub Release visibility." >&2
    restored=no
    expected_filter=
    if [[ "$release_was_draft" == true ]]; then
      restore_flags+=(--draft=true)
      expected_filter='.isDraft == true'
    fi
    if [[ "$release_was_prerelease" == true ]]; then
      restore_flags+=(--prerelease=true)
      expected_filter='.isPrerelease == true'
    fi
    if [[ "$release_was_draft" == true && "$release_was_prerelease" == true ]]; then
      expected_filter='.isDraft == true and .isPrerelease == true'
    fi
    if [[ -n "$expected_filter" ]]; then
      for attempt in 1 2 3; do
        if gh release edit "$release_tag" --repo "$repo" "${restore_flags[@]}" \
          && gh release view "$release_tag" --repo "$repo" --json isDraft,isPrerelease \
            | jq -e "$expected_filter" >/dev/null; then
          restored=yes
          break
        fi
        sleep "$retry_delay"
      done
    fi
    if [[ "$restored" != yes ]]; then
      echo "CRITICAL: unable to verify GitHub Release visibility rollback." >&2
      rollback_failed=yes
    fi
  fi
  [[ "$rollback_failed" == no ]]
}
