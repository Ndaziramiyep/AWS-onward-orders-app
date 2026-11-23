#!/usr/bin/env bash
# Waits for the AWS release of one image: EventBridge -> CodePipeline -> CodeDeploy blue/green canary.
# Exits 0 only when the pipeline run deploying this image has Succeeded (all traffic on the new
# version and the old tasks removed). A failed or rolled-back release fails, so a green GitHub
# check means the change is live for every user.
#
# Usage: IMAGE_DIGEST=sha256:... ./scripts/wait-for-release.sh
# IGNORE_EXECUTION_IDS (space separated) skips runs that already deployed this digest; rollback.sh
# sets it, because an image it rolls back to was deployed before.

# Stop on any error, unset variable or pipe failure.
set -euo pipefail

# Settings: shared ones from config.sh, overridable through the environment.
source "$(dirname "$0")/config.sh"
DIGEST="${IMAGE_DIGEST:?set IMAGE_DIGEST to the pushed image digest (sha256:...)}"
IGNORE_EXECUTION_IDS="${IGNORE_EXECUTION_IDS:-}"
FIND_MINUTES="${FIND_MINUTES:-10}"
WAIT_MINUTES="${WAIT_MINUTES:-40}"
CONSOLE="https://$REGION.console.aws.amazon.com/codesuite/codepipeline/pipelines/$PIPELINE/executions"

# Every AWS call has a hard time limit, so a stuck network call can never hang the job.
aws_call() {
  timeout 60 aws --region "$REGION" --cli-connect-timeout 10 --cli-read-timeout 30 "$@"
}

log() {
  echo "$(date -u +%H:%M:%S) $*"
}

# During a rebuild the first image is pushed before the 06-delivery stack creates the pipeline.
# That image is deployed by the ECS service itself, so there is no release to wait for.
if ! err="$(aws_call codepipeline get-pipeline-state --name "$PIPELINE" 2>&1 >/dev/null)"; then
  if [[ "$err" == *PipelineNotFoundException* ]]; then
    log "Pipeline $PIPELINE does not exist yet (first image of a rebuild) - nothing to wait for."
    exit 0
  fi
  echo "$err" >&2
  exit 1
fi

# Finds the pipeline run whose ECR source revision is this image's digest.
log "Looking for the $PIPELINE run that deploys $DIGEST ..."
EXEC_ID=""
deadline=$((SECONDS + FIND_MINUTES * 60))
while (( SECONDS < deadline )); do
  # Newest first; take the newest run for this digest that is not in IGNORE_EXECUTION_IDS.
  RUNS="$(aws_call codepipeline list-pipeline-executions --pipeline-name "$PIPELINE" --max-items 20 --output text \
    --query "pipelineExecutionSummaries[?sourceRevisions[?revisionId=='$DIGEST']].pipelineExecutionId" \
    2>/dev/null || true)"
  for run in $RUNS; do
    [[ "$run" == None || " $IGNORE_EXECUTION_IDS " == *" $run "* ]] && continue
    EXEC_ID="$run"
    break
  done
  [[ -n "$EXEC_ID" ]] && break
  sleep 15
done
if [[ -z "$EXEC_ID" ]]; then
  log "No pipeline run started for $DIGEST within $FIND_MINUTES min. Check the EventBridge rule."
  exit 1
fi
log "Pipeline run: $CONSOLE/$EXEC_ID/timeline?region=$REGION"

# Polls the run until it finishes. Prints on every change, and at least once a minute.
LAST=""
last_print=0
deadline=$((SECONDS + WAIT_MINUTES * 60))
while (( SECONDS < deadline )); do
  if ! STATUS="$(aws_call codepipeline get-pipeline-execution --pipeline-name "$PIPELINE" \
      --pipeline-execution-id "$EXEC_ID" --query 'pipelineExecution.status' --output text 2>&1)"; then
    log "Could not read the pipeline status, retrying: ${STATUS:-timed out}"
    sleep 15
    continue
  fi
  DEPLOY="$(aws_call codepipeline get-pipeline-state --name "$PIPELINE" --output text \
    --query "stageStates[?stageName=='Deploy'] | [0].actionStates[0].latestExecution.[status,summary]" \
    2>/dev/null || echo "unknown")"
  NOW="$STATUS | deploy: ${DEPLOY//$'\t'/ - }"
  if [[ "$NOW" != "$LAST" ]] || (( SECONDS - last_print >= 60 )); then
    log "$NOW"
    LAST="$NOW"
    last_print=$SECONDS
  fi

  case "$STATUS" in
    Succeeded)
      log "Release complete: every user is on the new version."
      [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "### Live on AWS: pipeline run \`$EXEC_ID\` succeeded" >> "$GITHUB_STEP_SUMMARY"
      exit 0 ;;
    Failed|Stopped|Cancelled|Superseded)
      log "Release $STATUS - CodeDeploy keeps or restores the previous version. See $CONSOLE/$EXEC_ID/timeline?region=$REGION"
      [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "### Release $STATUS: pipeline run \`$EXEC_ID\`" >> "$GITHUB_STEP_SUMMARY"
      exit 1 ;;
  esac
  sleep 15
done

log "Release still not finished after $WAIT_MINUTES min. See $CONSOLE/$EXEC_ID/timeline?region=$REGION"
exit 1
