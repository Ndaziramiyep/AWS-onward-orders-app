#!/usr/bin/env bash
# Rolls the service back to an image that was already built, without rebuilding it.
# 1. Uploads a deploy bundle to the bundle bucket: the latest task definition revision in ECS + that
#    commit's appspec. Only the image is rolled back; task settings (CPU, health check...) are kept.
# 2. Points the "latest" tag at the old image. That push starts the normal release:
#    EventBridge -> CodePipeline -> CodeDeploy blue/green, with the same canary and alarm rollback.
# 3. Waits for the release with wait-for-release.sh.
#
# This does not change git. main still holds the bad code, so the next push to main ships it
# again: revert the bad commit on main as well.
#
# Usage: ./scripts/rollback.sh <commit-sha> [--yes]   (settings in config.sh)
# The commit must be one that build-push.sh shipped (its 7-character SHA tag exists in ECR).

# Stop on any error, unset variable or pipe failure.
set -euo pipefail

# Settings: shared ones from config.sh, overridable through the environment.
source "$(dirname "$0")/config.sh"

TARGET="${1:?usage: rollback.sh <commit-sha> [--yes]}"
CONFIRMED="${2:-}"

# Resolve the target to a full commit; its short SHA is the image tag build-push.sh used.
if ! COMMIT="$(git rev-parse --verify --quiet "$TARGET^{commit}")"; then
  echo "Unknown commit $TARGET. Run 'git fetch' if it is not in your local clone." >&2
  exit 1
fi
SHA="${COMMIT::7}"

image_detail() { # <tag> <query>
  aws ecr describe-images --region "$REGION" --repository-name "$REPOSITORY" --image-ids imageTag="$1" \
    --query "imageDetails[0].$2" --output text 2>/dev/null
}

# The image to roll back to, and what "latest" points at now.
if ! read -r TARGET_DIGEST MEDIA_TYPE < <(image_detail "$SHA" '[imageDigest,imageManifestMediaType]') \
    || [[ -z "$TARGET_DIGEST" ]]; then
  echo "No image tagged $SHA in $REPOSITORY. Only commits pushed by build-push.sh can be rolled back to." >&2
  exit 1
fi
CURRENT_DIGEST="$(image_detail latest imageDigest || echo none)"

if [[ "$TARGET_DIGEST" == "$CURRENT_DIGEST" ]]; then
  echo "latest already points at $SHA ($TARGET_DIGEST). Nothing to roll back."
  exit 0
fi

echo "Roll back $REPOSITORY:latest"
echo "  from: $CURRENT_DIGEST"
echo "  to:   $SHA ($TARGET_DIGEST) - $(git log -1 --format='%s' "$COMMIT")"
if [[ "$CONFIRMED" != "--yes" ]]; then
  read -r -p "This starts a production release. Continue? [y/N] " answer
  [[ "$answer" == [yY] ]] || { echo "Cancelled."; exit 1; }
fi

# Pipeline runs that already deployed this digest. wait-for-release.sh skips them, so it waits
# for the new run instead of reporting the old, already finished one.
OLD_RUNS="$(aws codepipeline list-pipeline-executions --region "$REGION" --pipeline-name "$PIPELINE" \
  --max-items 20 --output text \
  --query "pipelineExecutionSummaries[?sourceRevisions[?revisionId=='$TARGET_DIGEST']].pipelineExecutionId" \
  2>/dev/null | tr '\t' ' ' | grep -v '^None$' || true)"

# Bundle first, like build-push.sh: the run started by the tag move must read this commit's specs.
BUNDLE_DIR="$(mktemp -d)"
trap 'rm -rf "$BUNDLE_DIR"' EXIT
"$(dirname "$0")/make-bundle.sh" "$COMMIT" "$BUNDLE_DIR/bundle.zip"
aws s3 cp "$BUNDLE_DIR/bundle.zip" "s3://$BUNDLE_BUCKET/$BUNDLE_KEY" --region "$REGION" \
  --metadata "commit=$COMMIT,rollback=true" --only-show-errors
echo "Uploaded the $SHA deploy bundle to s3://$BUNDLE_BUCKET/$BUNDLE_KEY"

# Move "latest" by re-putting the old image's manifest under that tag (no pull or push of layers).
MANIFEST="$(aws ecr batch-get-image --region "$REGION" --repository-name "$REPOSITORY" --image-ids imageTag="$SHA" \
  --query 'images[0].imageManifest' --output text)"
aws ecr put-image --region "$REGION" --repository-name "$REPOSITORY" --image-tag latest \
  --image-manifest "$MANIFEST" --image-manifest-media-type "$MEDIA_TYPE" >/dev/null
echo "latest now points at $SHA. The release pipeline is starting."

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  echo "### Rolling back to \`$SHA\` (\`$TARGET_DIGEST\`)" >> "$GITHUB_STEP_SUMMARY"
fi

IMAGE_DIGEST="$TARGET_DIGEST" IGNORE_EXECUTION_IDS="$OLD_RUNS" "$(dirname "$0")/wait-for-release.sh"
