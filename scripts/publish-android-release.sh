#!/usr/bin/env bash

# Publish a prepared Android GitHub Release and route only Android endpoints to
# an immutable tagged Cloud Run origin. The Google AI Studio frontend image and
# homepage assets remain unchanged.
set -euo pipefail

mode=${1:-}
release_tag=${2:-}
if [[ "$mode" != --preflight && "$mode" != --apply ]] || [[ -z "$release_tag" ]] || [[ $# -ne 2 ]]; then
  echo "Usage: $0 <--preflight|--apply> <android-release-tag>" >&2
  exit 64
fi
if [[ ! "$release_tag" =~ ^android-v[0-9]+\.[0-9]+\.[0-9]+-build[0-9]+$ ]]; then
  echo "Release tag is not an Android production tag: $release_tag" >&2
  exit 65
fi

repo=${HKMOVIE67_RELEASE_REPOSITORY:-HKMovie67/HKMovie67}
project=${HKMOVIE67_GCLOUD_PROJECT:-gen-lang-client-0178764531}
region=${HKMOVIE67_CLOUD_RUN_REGION:-us-west1}
gateway_service=${HKMOVIE67_GATEWAY_SERVICE:-hkmovie67}
origin_service=${HKMOVIE67_ANDROID_ORIGIN_SERVICE:-hkmovie67-android}
runtime_service_account=${HKMOVIE67_RUNTIME_SERVICE_ACCOUNT:-736766866304-compute@developer.gserviceaccount.com}
base_image=${HKMOVIE67_ANDROID_BASE_IMAGE:-us-west1-docker.pkg.dev/ai-studio-registry-prod/ai-studio/deploy-container@sha256:b2ad2b869a8118c9dbac684a9fed971c5298f90e1ea2d2efd21bff5567975e8e}

for command in curl gcloud gh grep jq sha256sum; do
  command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 69; }
done
gh auth status >/dev/null 2>&1 || { echo "GitHub authentication is unavailable." >&2; exit 77; }
gcloud auth print-access-token >/dev/null 2>&1 || { echo "Google keyless authentication is unavailable." >&2; exit 77; }

work_dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/hkmovie67-android-release.XXXXXX")
assets_dir="$work_dir/assets"
mkdir -p "$assets_dir"
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

release_json="$work_dir/release.json"
gh release view "$release_tag" --repo "$repo" \
  --json isDraft,isPrerelease,tagName,name,targetCommitish,assets >"$release_json"
jq -e --arg tag "$release_tag" \
  '.tagName == $tag and (.assets | length) == 8 and ([.assets[].name] | unique | length) == 8' \
  "$release_json" >/dev/null || { echo "Release must contain exactly eight unique assets." >&2; exit 65; }

for asset in android.html android-icon.png delete-account.html android-update.json patch-nginx-android-entry.mjs runtime-start.sh; do
  jq -e --arg name "$asset" 'any(.assets[]; .name == $name)' "$release_json" >/dev/null || {
    echo "Required release asset is missing: $asset" >&2; exit 65;
  }
done
[[ $(jq '[.assets[] | select(.name | endswith(".apk"))] | length' "$release_json") -eq 2 ]] || {
  echo "Release must contain exactly two APKs." >&2; exit 65;
}

gh release download "$release_tag" --repo "$repo" --dir "$assets_dir"
while IFS=$'\t' read -r name size digest; do
  file="$assets_dir/$name"
  [[ -f "$file" && $(wc -c <"$file" | tr -d ' ') == "$size" ]] || {
    echo "Release asset size mismatch: $name" >&2; exit 65;
  }
  actual=$(sha256sum "$file" | awk '{print $1}')
  [[ "$digest" == "sha256:$actual" ]] || { echo "Release asset digest mismatch: $name" >&2; exit 65; }
done < <(jq -r '.assets[] | [.name, (.size | tostring), .digest] | @tsv' "$release_json")

manifest="$assets_dir/android-update.json"
jq -e --arg tag "$release_tag" '
  .schemaVersion == 1 and
  .packageName == "com.hkmovie67.app" and
  .channel == "galaxy" and
  (.versionName | type == "string" and length > 0) and
  (.versionCode | type == "number" and . > 0) and
  (.artifacts["arm64-v8a"].sha256 | test("^[0-9a-f]{64}$")) and
  (.artifacts["armeabi-v7a"].sha256 | test("^[0-9a-f]{64}$"))
' "$manifest" >/dev/null || { echo "Android update manifest is invalid." >&2; exit 65; }

version=$(jq -r '.versionName' "$manifest")
build=$(jq -r '.versionCode' "$manifest")
arm64_sha=$(jq -r '.artifacts["arm64-v8a"].sha256' "$manifest")
armv7_sha=$(jq -r '.artifacts["armeabi-v7a"].sha256' "$manifest")
[[ "$release_tag" == "android-v${version}-build${build}" ]] || {
  echo "Release tag and update manifest disagree." >&2; exit 65;
}

arm64_file=
armv7_file=
while IFS= read -r apk; do
  sha=$(sha256sum "$apk" | awk '{print $1}')
  [[ "$sha" == "$arm64_sha" ]] && arm64_file=$(basename "$apk")
  [[ "$sha" == "$armv7_sha" ]] && armv7_file=$(basename "$apk")
done < <(find "$assets_dir" -maxdepth 1 -type f -name '*.apk' -print)
[[ -n "$arm64_file" && -n "$armv7_file" && "$arm64_file" != "$armv7_file" ]] || {
  echo "APK hashes do not match both manifest architectures." >&2; exit 65;
}

runtime_start="$assets_dir/runtime-start.sh"
runtime_sha=$(sha256sum "$runtime_start" | awk '{print $1}')
asset_base="https://github.com/$repo/releases/download/$release_tag"
grep -F "asset_base='$asset_base'" "$runtime_start" >/dev/null || {
  echo "Runtime bootstrap does not target this immutable release." >&2; exit 65;
}

gateway_json="$work_dir/gateway-before.json"
gcloud run services describe "$gateway_service" --project "$project" --region "$region" --format=json >"$gateway_json"
jq -e '
  .metadata.labels["managed-by"] == "google-ai-studio" and
  .metadata.annotations["generativelanguage.googleapis.com/type"] == "fullstack-applet" and
  ([.spec.template.spec.containers[].name] == ["nginx-container"])
' "$gateway_json" >/dev/null || { echo "Frontend gateway ownership or container contract changed." >&2; exit 65; }
previous_revision=$(jq -r '.status.traffic[] | select((.percent // 0) == 100) | .revisionName' "$gateway_json" | head -1)
[[ -n "$previous_revision" ]] || { echo "Frontend gateway lacks one 100% production revision." >&2; exit 65; }
before_assets=$(curl -fsSL https://hkmovie67.com/ | grep -Eo '/assets/index-[A-Za-z0-9_-]+\.(js|css)' | sort -u)
[[ -n "$before_assets" ]] || { echo "Unable to capture production homepage assets." >&2; exit 65; }

if [[ "$mode" == --preflight ]]; then
  echo "Android release preflight passed for $release_tag; no mutation was made."
  exit 0
fi

if jq -e '.isDraft == true' "$release_json" >/dev/null; then
  gh release edit "$release_tag" --repo "$repo" --draft=false --prerelease=false
elif jq -e '.isPrerelease == true' "$release_json" >/dev/null; then
  gh release edit "$release_tag" --repo "$repo" --prerelease=false
fi

public_dir="$work_dir/public"
mkdir -p "$public_dir"
while IFS=$'\t' read -r name _ digest; do
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    "$asset_base/$name" --output "$public_dir/$name"
  actual=$(sha256sum "$public_dir/$name" | awk '{print $1}')
  [[ "$digest" == "sha256:$actual" ]] || { echo "Public release asset mismatch: $name" >&2; exit 65; }
done < <(jq -r '.assets[] | [.name, (.size | tostring), .digest] | @tsv' "$release_json")

bootstrap="set -eu; f=/tmp/hkmovie67-runtime-start.sh; curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location '$asset_base/runtime-start.sh' --output \"\$f\"; actual=\$(sha256sum \"\$f\" | awk '{print \$1}'); [ \"\$actual\" = '$runtime_sha' ] || exit 65; exec /bin/sh \"\$f\""
origin_tag="android-build${build}"
origin_traffic_args=(--no-traffic --tag "$origin_tag")
if ! gcloud run services describe "$origin_service" --project "$project" --region "$region" >/dev/null 2>&1; then
  # A brand-new isolated origin cannot use --no-traffic. It is not connected
  # to the production gateway until all origin and gateway canary checks pass.
  origin_traffic_args=(--tag "$origin_tag")
fi
gcloud run deploy "$origin_service" --project "$project" --region "$region" --quiet \
  --image "$base_image" --service-account "$runtime_service_account" \
  --command /bin/sh --args="^~^-c~$bootstrap" "${origin_traffic_args[@]}" --allow-unauthenticated \
  --labels hkmovie67_android_origin=managed

origin_json="$work_dir/origin.json"
gcloud run services describe "$origin_service" --project "$project" --region "$region" --format=json >"$origin_json"
origin_url=$(jq -r --arg tag "$origin_tag" '.status.traffic[] | select(.tag == $tag) | .url' "$origin_json")
[[ -n "$origin_url" && "$origin_url" != null ]] || { echo "Tagged Android origin URL is unavailable." >&2; exit 1; }
curl --retry 20 --retry-delay 2 --retry-all-errors -fsSL "$origin_url/api/health/android-entry" |
  jq -e --arg version "$version" --argjson build "$build" '.version == $version and .build == $build' >/dev/null
curl --retry 10 --retry-delay 2 --retry-all-errors -fsSL "$origin_url/android-update.json" |
  jq -e --arg arm64 "$arm64_sha" --arg armv7 "$armv7_sha" \
    '.artifacts["arm64-v8a"].sha256 == $arm64 and .artifacts["armeabi-v7a"].sha256 == $armv7' >/dev/null

promoted=no
rollback() {
  status=$?
  trap - EXIT
  if [[ $status -ne 0 && "$promoted" == yes ]]; then
    echo "Live verification failed; restoring gateway traffic to $previous_revision." >&2
    gcloud run services update-traffic "$gateway_service" --project "$project" --region "$region" \
      --to-revisions "$previous_revision=100" --quiet || true
  fi
  rm -rf "$work_dir"
  exit "$status"
}
trap rollback EXIT

gcloud run services update "$gateway_service" --project "$project" --region "$region" --quiet \
  --container nginx-container --update-env-vars "ANDROID_SERVICE_ORIGIN=$origin_url" \
  --no-traffic --tag android-gateway-candidate
gateway_candidate_json="$work_dir/gateway-candidate.json"
gcloud run services describe "$gateway_service" --project "$project" --region "$region" --format=json >"$gateway_candidate_json"
candidate_revision=$(jq -r '.status.latestCreatedRevisionName' "$gateway_candidate_json")
candidate_url=$(jq -r '.status.traffic[] | select(.tag == "android-gateway-candidate") | .url' "$gateway_candidate_json")
[[ -n "$candidate_revision" && -n "$candidate_url" && "$candidate_url" != null ]] || {
  echo "Gateway candidate was not created." >&2; exit 1;
}
jq -e --arg previous "$previous_revision" --arg candidate "$candidate_revision" '
  any(.status.traffic[]; (.percent // 0) == 100 and .revisionName == $previous) and
  .status.latestCreatedRevisionName == $candidate
' "$gateway_candidate_json" >/dev/null || { echo "Gateway traffic drifted before promotion." >&2; exit 1; }
curl --retry 20 --retry-delay 2 --retry-all-errors -fsSL "$candidate_url/api/health/android-entry" |
  jq -e --arg version "$version" --argjson build "$build" '.version == $version and .build == $build' >/dev/null
candidate_assets=$(curl -fsSL "$candidate_url/" | grep -Eo '/assets/index-[A-Za-z0-9_-]+\.(js|css)' | sort -u)
[[ "$candidate_assets" == "$before_assets" ]] || { echo "Gateway candidate changed homepage assets." >&2; exit 1; }

gcloud run services update-traffic "$gateway_service" --project "$project" --region "$region" --to-latest --quiet
promoted=yes
live_health=$(curl --retry 20 --retry-delay 2 --retry-all-errors -fsSL https://hkmovie67.com/api/health/android-entry)
jq -e --arg version "$version" --argjson build "$build" '.version == $version and .build == $build' <<<"$live_health" >/dev/null
live_manifest=$(curl --retry 10 --retry-delay 2 --retry-all-errors -fsSL https://hkmovie67.com/android-update.json)
jq -e --arg arm64 "$arm64_sha" --arg armv7 "$armv7_sha" \
  '.artifacts["arm64-v8a"].sha256 == $arm64 and .artifacts["armeabi-v7a"].sha256 == $armv7' <<<"$live_manifest" >/dev/null
after_assets=$(curl -fsSL https://hkmovie67.com/ | grep -Eo '/assets/index-[A-Za-z0-9_-]+\.(js|css)' | sort -u)
[[ "$after_assets" == "$before_assets" ]] || { echo "Production homepage assets changed during Android publication." >&2; exit 1; }

promoted=no
trap cleanup EXIT
echo "Published $release_tag through immutable origin $origin_url and gateway revision $candidate_revision."
