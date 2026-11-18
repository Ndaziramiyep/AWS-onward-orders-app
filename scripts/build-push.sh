#!/usr/bin/env bash
# Builds the image once and pushes two tags: the short git SHA (immutable, rollback target)
# and "latest" (moving tag; its push starts the AWS release through EventBridge).
#
# Usage: REGISTRY=<account>.dkr.ecr.<region>.amazonaws.com ./scripts/build-push.sh
# In GitHub Actions it writes image_digest=sha256:... to $GITHUB_OUTPUT for wait-for-release.sh.

# Stop on any error, unset variable or pipe failure.
set -euo pipefail

# Settings, overridable through the environment.
REGION="${AWS_REGION:-eu-west-1}"
REPOSITORY="${ECR_REPOSITORY:-onward-orders-lab}"
REGISTRY="${REGISTRY:?set REGISTRY to <account>.dkr.ecr.<region>.amazonaws.com}"
COMMIT="${GITHUB_SHA:-$(git rev-parse HEAD)}"
SHA="${COMMIT::7}"
IMAGE="$REGISTRY/$REPOSITORY"

# Build once with both tags; the SHA is baked in as the app version.
docker build --build-arg APP_VERSION="$SHA" -t "$IMAGE:$SHA" -t "$IMAGE:latest" .

# Immutable tag first, moving tag last: the "latest" push is what triggers the release.
docker push "$IMAGE:$SHA"
docker push "$IMAGE:latest"

# The digest identifies this exact image in the pipeline run that deploys it.
DIGEST="$(aws ecr describe-images --region "$REGION" --repository-name "$REPOSITORY" \
  --image-ids imageTag="$SHA" --query 'imageDetails[0].imageDigest' --output text)"
echo "Pushed $IMAGE:$SHA ($DIGEST)"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "image_digest=$DIGEST" >> "$GITHUB_OUTPUT"
  echo "### Pushed \`$IMAGE:$SHA\` (\`$DIGEST\`)" >> "$GITHUB_STEP_SUMMARY"
fi
