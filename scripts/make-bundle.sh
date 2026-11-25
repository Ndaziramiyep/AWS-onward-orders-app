#!/usr/bin/env bash
# Builds the deploy bundle: taskdef.json + appspec.yaml at the zip root, which is what the
# pipeline's CodeDeployToECS action reads.
# - taskdef.json is generated from the latest ACTIVE revision of the task definition family in ECS
#   (the bootstrap revision from stack 04-ecs, then the revisions the pipeline registers): read-only
#   fields are removed and the image becomes <IMAGE1_NAME>, which the pipeline replaces with the new
#   image URI. This repo keeps no task definition of its own. To change CPU, memory, the health
#   check or env vars, register a new revision of the family; the next release deploys it.
# - appspec.yaml is taken from git at <commit>, so a rollback uses the AppSpec of that commit.
#
# Usage: ./scripts/make-bundle.sh <commit> <out.zip>
# Exit code 2: the family has no active revision yet (stack 04-ecs not created, first image of a rebuild).
# Needs the AWS CLI (ecs:DescribeTaskDefinition, ecs:ListTagsForResource) and Python 3.

# Stop on any error, unset variable or pipe failure.
set -euo pipefail

# Settings: shared ones from config.sh, overridable through the environment.
source "$(dirname "$0")/config.sh"

REF="${1:?usage: make-bundle.sh <commit> <out.zip>}"
OUT="${2:?usage: make-bundle.sh <commit> <out.zip>}"

# A Python that really runs (on Windows "python3" can be a Microsoft Store stub).
PY=""
for candidate in python3 python; do
  if "$candidate" -c 'import sys' >/dev/null 2>&1; then PY="$candidate"; break; fi
done
if [[ -z "$PY" ]]; then
  echo "Need Python 3 to build the deploy bundle" >&2
  exit 1
fi

has_file() {
  git cat-file -e "$REF:$1" 2>/dev/null
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The latest ACTIVE revision of the family (naming only the family resolves to it).
if ! aws ecs describe-task-definition --region "$REGION" --task-definition "$TASK_FAMILY" \
    --include TAGS --output json > "$WORK/described.json" 2> "$WORK/ecs.err"; then
  if grep -q "Unable to describe task definition" "$WORK/ecs.err"; then
    echo "No active revision of task definition family $TASK_FAMILY (stack 04-ecs not created yet)." >&2
    exit 2
  fi
  cat "$WORK/ecs.err" >&2
  exit 1
fi
"$PY" -c 'import json,sys; t=json.load(open(sys.argv[1]))["taskDefinition"]; print("Generating taskdef.json from", t["taskDefinitionArn"])' \
  "$WORK/described.json"

# Turn the registered revision back into register-task-definition input.
"$PY" - "$WORK/described.json" "$WORK/taskdef.json" <<'EOF'
import json, sys

described = json.load(open(sys.argv[1]))
taskdef = described["taskDefinition"]

# Fields ECS sets on registration; register-task-definition rejects them.
for field in ("taskDefinitionArn", "revision", "status", "requiresAttributes", "compatibilities",
              "registeredAt", "registeredBy", "deregisteredAt"):
    taskdef.pop(field, None)

apps = [c for c in taskdef.get("containerDefinitions", []) if c.get("name") == "app"]
if not apps:
    sys.exit("taskdef: no container named 'app' (appspec.yaml routes traffic to it)")
apps[0]["image"] = "<IMAGE1_NAME>"  # The pipeline puts the new image URI here

# Keep the revision's tags (aws:* are reserved, e.g. CloudFormation's on the bootstrap revision).
tags = [t for t in described.get("tags", []) if not t["key"].startswith("aws:")]
tags = [t for t in tags if t["key"] != "ManagedBy"] + [{"key": "ManagedBy", "value": "codepipeline"}]
taskdef["tags"] = tags

json.dump(taskdef, open(sys.argv[2], "w"), indent=2)
EOF

# AppSpec: deploy/ in new commits, repo root in old ones.
if has_file deploy/appspec.yaml; then
  git show "$REF:deploy/appspec.yaml" > "$WORK/appspec.yaml"
elif has_file appspec.yaml; then
  git show "$REF:appspec.yaml" > "$WORK/appspec.yaml"
else
  echo "No deploy/appspec.yaml or appspec.yaml in $REF" >&2
  exit 1
fi

rm -f "$OUT"
if command -v zip >/dev/null 2>&1; then
  zip -j -q "$OUT" "$WORK/taskdef.json" "$WORK/appspec.yaml"
else
  "$PY" -c 'import sys,zipfile,os; z=zipfile.ZipFile(sys.argv[1],"w",zipfile.ZIP_DEFLATED); [z.write(f, os.path.basename(f)) for f in sys.argv[2:]]; z.close()' \
    "$OUT" "$WORK/taskdef.json" "$WORK/appspec.yaml"
fi
