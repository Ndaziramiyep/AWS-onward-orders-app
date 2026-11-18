#!/usr/bin/env bash
# Waits for the AWS release of one image: EventBridge -> CodePipeline -> CodeDeploy blue/green canary.
# Exits 0 only when the pipeline run deploying this image has Succeeded (all traffic on the new
# version and the old tasks removed). A failed or rolled-back release fails, so a green GitHub
# check means the change is live for every user.
#
# Usage: IMAGE_DIGEST=sha256:... ./scripts/wait-for-release.sh

# Stop on any error, unset variable or pipe failure.
set -euo pipefail

# Settings, overridable through the environment.
REGION="${AWS_REGION:-eu-west-1}"
PIPELINE="${PIPELINE_NAME:-onward-orders-lab-pipeline}"
DIGEST="${IMAGE_DIGEST:?set IMAGE_DIGEST to the pushed image digest (sha256:...)}"
FIND_MINUTES="${FIND_MINUTES:-10}"
WAIT_MINUTES="${WAIT_MINUTES:-40}"
CONSOLE="https://$REGION.console.aws.amazon.com/codesuite/codepipeline/pipelines/$PIPELINE/executions"

# During a rebuild the first image is pushed before the 06-delivery stack creates the pipeline.
# That image is deployed by the ECS service itself, so there is no release to wait for.
if ! aws codepipeline get-pipeline-state --region "$REGION" --name "$PIPELINE" >/dev/null 2>/tmp/pipeline-err; then
  if grep -q PipelineNotFoundException /tmp/pipeline-err; then
    echo "Pipeline $PIPELINE does not exist yet (first image of a rebuild) - nothing to wait for."
    exit 0
  fi
  cat /tmp/pipeline-err >&2
  exit 1
fi

# Finds the pipeline run whose ECR source revision is this image's digest.
echo "Looking for the $PIPELINE run that deploys $DIGEST ..."
EXEC_ID=""
for _ in $(seq 1 $((FIND_MINUTES * 4))); do
  EXEC_ID="$(aws codepipeline list-pipeline-executions --region "$REGION" --pipeline-name "$PIPELINE" \
    --max-items 20 --output text \
    --query "pipelineExecutionSummaries[?sourceRevisions[?revisionId=='$DIGEST']].pipelineExecutionId | [0]" \
    | head -n1)"
  [[ -n "$EXEC_ID" && "$EXEC_ID" != None ]] && break
  EXEC_ID=""
  sleep 15
done
[[ -n "$EXEC_ID" ]] || { echo "No pipeline run started for $DIGEST within $FIND_MINUTES min. Check the EventBridge rule."; exit 1; }
echo "Pipeline run: $CONSOLE/$EXEC_ID/timeline?region=$REGION"

# Polls the run, printing each change of the pipeline and deploy-stage status.
LAST=""
for _ in $(seq 1 $((WAIT_MINUTES * 4))); do
  STATUS="$(aws codepipeline get-pipeline-execution --region "$REGION" --pipeline-name "$PIPELINE" \
    --pipeline-execution-id "$EXEC_ID" --query 'pipelineExecution.status' --output text)"
  DEPLOY="$(aws codepipeline get-pipeline-state --region "$REGION" --name "$PIPELINE" --output text \
    --query "stageStates[?stageName=='Deploy'] | [0].actionStates[0].latestExecution.[status,summary]" 2>/dev/null || true)"
  NOW="$STATUS | deploy: ${DEPLOY//$'\t'/ - }"
  [[ "$NOW" != "$LAST" ]] && echo "$(date -u +%H:%M:%S) $NOW"
  LAST="$NOW"

  case "$STATUS" in
    Succeeded)
      echo "Release complete: every user is on the new version."
      [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "### Live on AWS: pipeline run \`$EXEC_ID\` succeeded" >> "$GITHUB_STEP_SUMMARY"
      exit 0 ;;
    Failed|Stopped|Cancelled|Superseded)
      echo "Release $STATUS - CodeDeploy keeps or restores the previous version. See $CONSOLE/$EXEC_ID/timeline?region=$REGION"
      [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "### Release $STATUS: pipeline run \`$EXEC_ID\`" >> "$GITHUB_STEP_SUMMARY"
      exit 1 ;;
  esac
  sleep 15
done

echo "Release still $STATUS after $WAIT_MINUTES min."
exit 1
