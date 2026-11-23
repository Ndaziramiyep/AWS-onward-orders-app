#!/usr/bin/env bash
# Builds the image once and pushes two tags: the short git SHA (immutable, rollback target)
# and "latest" (moving tag; its push starts the AWS release through EventBridge).
#
# Usage: REGISTRY=<account>.dkr.ecr.<region>.amazonaws.com ./scripts/build-push.sh
# In GitHub Actions it writes image_digest=sha256:... to $GITHUB_OUTPUT for wait-for-release.sh.

# Stop on any error, unset variable or pipe failure.
set -euo pipefail

# Settings: shared ones from config.sh, overridable through the environment.
source "$(dirname "$0")/config.sh"
REGISTRY="${REGISTRY:?set REGISTRY to <account>.dkr.ecr.<region>.amazonaws.com}"
COMMIT="${GITHUB_SHA:-$(git rev-parse HEAD)}"
SHA="${COMMIT::7}"
IMAGE="$REGISTRY/$REPOSITORY"

# Digest and manifest media type of an image tag, empty if the tag does not exist.
image_detail() { # <tag> <query>
  aws ecr describe-images --region "$REGION" --repository-name "$REPOSITORY" --image-ids imageTag="$1" \
    --query "imageDetails[0].$2" --output text 2>/dev/null || true
}

# SHA tags are immutable, so a re-run of a commit that already pushed its image (e.g. a run that
# failed after the push) must reuse that image: a rebuild has a new digest and ECR would reject it.
EXISTING="$(image_detail "$SHA" imageDigest)"
if [[ -n "$EXISTING" && "$EXISTING" != None ]]; then
  echo "$IMAGE:$SHA already exists ($EXISTING); reusing it instead of rebuilding."
else
  # Build once with both tags; the SHA is baked in as the app version.
  docker build --build-arg APP_VERSION="$SHA" -t "$IMAGE:$SHA" -t "$IMAGE:latest" .
  docker push "$IMAGE:$SHA"
fi

# Deploy bundle: taskdef.json (converted from deploy/taskdef.yaml) + appspec.yaml, see make-bundle.sh.
# Uploaded BEFORE the "latest" push, so the pipeline run that push starts reads this commit's specs.
BUNDLE="$(mktemp -d)/bundle.zip"
"$(dirname "$0")/make-bundle.sh" "$COMMIT" "$BUNDLE"
aws s3 cp "$BUNDLE" "s3://$BUNDLE_BUCKET/$BUNDLE_KEY" --region "$REGION" \
  --metadata "commit=$COMMIT" --only-show-errors
echo "Uploaded deploy bundle to s3://$BUNDLE_BUCKET/$BUNDLE_KEY"

# The digest identifies this exact image in the pipeline run that deploys it.
DIGEST="$(image_detail "$SHA" imageDigest)"

# Moving tag last: the "latest" push is what triggers the release.
if [[ -z "$EXISTING" || "$EXISTING" == None ]]; then
  docker push "$IMAGE:latest"
elif [[ "$(image_detail latest imageDigest)" == "$DIGEST" ]]; then
  echo "latest already points at $SHA; its release was started by the earlier run."
else
  # Re-run: point "latest" at the existing image by re-putting its manifest (no layers move).
  MEDIA_TYPE="$(image_detail "$SHA" imageManifestMediaType)"
  MANIFEST="$(aws ecr batch-get-image --region "$REGION" --repository-name "$REPOSITORY" \
    --image-ids imageTag="$SHA" --query 'images[0].imageManifest' --output text)"
  aws ecr put-image --region "$REGION" --repository-name "$REPOSITORY" --image-tag latest \
    --image-manifest "$MANIFEST" --image-manifest-media-type "$MEDIA_TYPE" >/dev/null
fi
echo "Pushed $IMAGE:$SHA ($DIGEST)"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "image_digest=$DIGEST" >> "$GITHUB_OUTPUT"
  echo "### Pushed \`$IMAGE:$SHA\` (\`$DIGEST\`)" >> "$GITHUB_STEP_SUMMARY"
fi
