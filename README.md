# AWS-onward-orders-app

The Onward Logistics order system: a single Flask container that serves the UI and the order logic on port **8080**. Merging to `main` is the only step needed to release. GitHub Actions tests the code, builds the image, and pushes it to ECR with OIDC (no stored AWS keys). The ECR push triggers EventBridge, then CodePipeline, then a CodeDeploy blue/green release.

The infrastructure lives in **[AWS-onward-orders-app-infra](https://github.com/Ndaziramiyep/AWS-onward-orders-app-infra)**.

## Layout

| Path | Purpose |
| --- | --- |
| `app/main.py` | Routes: `/` (page), `/orders` (POST), `/health` (ALB check), `/version`, `/cpu` (load demo) |
| `app/settings.py` | Name, lab name, release note, and the `FORCE_UNHEALTHY` bad-release demo switch |
| `app/templates/index.html` | Page showing full name, lab name, version, task ID, and AZ |
| `tests/` | Unit tests that gate every build |
| `Dockerfile` | Multi-stage, slim base image, non-root user, gunicorn |
| `.github/workflows/ci.yml` | Unit tests on every pull request; on `main`: tests, then `scripts/build-push.sh`, then `release.yml` |
| `.github/workflows/release.yml` | Waits for the AWS release with `scripts/wait-for-release.sh`; can also be run by hand with an image digest |
| `.github/workflows/rollback.yml` | Manual run of `scripts/rollback.sh` from the Actions tab |
| `scripts/config.sh` | Shared settings for the scripts (region, ECR repository, pipeline, bundle bucket and key) |
| `scripts/build-push.sh` | Builds the image once and pushes `:<sha>` then `:latest` (the `:latest` push starts the AWS release) |
| `scripts/make-bundle.sh` | Builds the deploy bundle: `taskdef.json` (generated from the latest ECS task definition revision of the `onward-orders-lab` family) and the commit's `appspec.yaml` |
| `scripts/wait-for-release.sh` | Finds the CodePipeline run for the pushed image digest and waits for it: green only when CodeDeploy has finished, red if it fails or rolls back |
| `scripts/rollback.sh` | Points `:latest` back at an already-built `:<sha>` image with a bundle holding that commit's AppSpec, then waits for the release |
| `deploy/appspec.yaml` | CodeDeploy AppSpec. `<TASK_DEFINITION>` is filled in by the pipeline. |

This repo has **no task definition**. On every push to `main`, `scripts/make-bundle.sh` copies the latest active revision of the `onward-orders-lab` family from ECS (read-only fields removed, tags kept, image set to `<IMAGE1_NAME>`) and writes it as `taskdef.json` next to `appspec.yaml` at the zip root; the pipeline replaces `<IMAGE1_NAME>` with the new image URI and registers the next revision. To change CPU, memory, the health check or logs, register a new revision of the `onward-orders-lab` family (e.g. ECS console → Task definitions → Create new revision), then release (push or re-run `ci`).

## Run locally

```bash
docker build --build-arg APP_VERSION=local -t onward-orders:local .
docker run --rm -p 8080:8080 onward-orders:local
# open http://localhost:8080
```

Tests: `pip install -r app/requirements.txt pytest && pytest -q`

## Release demos

- **New version:** change `RELEASE_NOTE` in `app/settings.py`, then commit and push to `main`. The GitHub Actions run stays in progress until the AWS release finishes (about 13 minutes) and turns green only when every user is on the new version. During the 5-minute canary about 10% of requests already get the new version; that is expected.
- **Bad release and automatic rollback:** set `FORCE_UNHEALTHY = True` and push. The green tasks fail `/health`, the unhealthy-host alarm fires, and CodeDeploy rolls back. Set it back to `False` and push again.
- **Manual rollback (after a release has finished):** Actions tab, then **rollback**, then **Run workflow** on `main` with the commit SHA to go back to. Locally: `./scripts/rollback.sh <sha>` (needs AWS credentials, plus `yq` or Python with PyYAML). The old image is redeployed through the same blue/green canary, with no rebuild. `main` still holds the bad code, so also `git revert` the bad commit or the next push ships it again. While a release is still running, stop it instead: `aws deploy stop-deployment --deployment-id <id> --auto-rollback-enabled`.
- **Auto scaling:** `hey -z 3m -c 40 "http://<alb-dns>/cpu?seconds=1"`

## Security

No AWS secrets are stored in this repository or its settings. The role ARN in the OIDC login step of each workflow in `.github/workflows/` is not a secret. The role trusts only this repo's `main` branch and can only push to the `onward-orders-lab` ECR repository.
