# Shared settings for the release scripts; sourced, not run. Each one can be overridden through
# the environment. The values are outputs of the infra stacks (AWS-onward-orders-app-infra).
# The GitHub role ARN lives in the OIDC login step of each workflow in .github/workflows/.

REGION="${AWS_REGION:-eu-west-1}"
REPOSITORY="${ECR_REPOSITORY:-onward-orders-lab}"                                 # 01-foundation
PIPELINE="${PIPELINE_NAME:-onward-orders-lab-pipeline}"                           # 06-delivery
BUNDLE_BUCKET="${BUNDLE_BUCKET:-onward-orders-lab-bundle-648637468459-eu-west-1}" # BundleBucketName, 01-foundation
BUNDLE_KEY="${BUNDLE_KEY:-deploy/bundle.zip}"                                     # BundleObjectKey, 01-foundation

# Never open a pager for AWS CLI output.
export AWS_PAGER=""
