#!/usr/bin/env bash

restore_android_release_state() {
  status=$1
  promoted=$2
  release_visibility_changed=$3
  release_was_draft=$4
  release_was_prerelease=$5
  gateway_service=$6
  project=$7
  region=$8
  previous_revision=$9
  release_tag=${10}
  repo=${11}

  [[ "$status" -ne 0 ]] || return 0
  if [[ "$promoted" == yes ]]; then
    echo "Release verification failed; restoring gateway traffic to $previous_revision." >&2
    gcloud run services update-traffic "$gateway_service" --project "$project" --region "$region" \
      --to-revisions "$previous_revision=100" --quiet || true
  fi
  if [[ "$release_visibility_changed" == yes ]]; then
    echo "Release verification failed; restoring prior GitHub Release visibility." >&2
    if [[ "$release_was_draft" == true ]]; then
      gh release edit "$release_tag" --repo "$repo" --draft=true || true
    elif [[ "$release_was_prerelease" == true ]]; then
      gh release edit "$release_tag" --repo "$repo" --prerelease=true || true
    fi
  fi
}
