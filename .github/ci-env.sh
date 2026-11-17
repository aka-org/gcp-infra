#!/usr/bin/env bash
# Gives a workflow job what it needs to act in one project, from the
# ci.env files the bootstraps wrote (identifiers only, nothing secret).
#
#   .github/ci-env.sh <project folder>      e.g. pokechamps/prod
#
# Exports to the job's later steps (through $GITHUB_ENV):
# - the project's own ci.env values (GCP_PROJECT_ID, GCP_SERVICE_ACCOUNT,
#   GCP_PLAN_SERVICE_ACCOUNT, GCP_WORKLOAD_IDENTITY_PROVIDER,
#   TF_STATE_BUCKET) and TF_VAR_project_id;
# - TF_VAR_<name>_project_id for every bootstrapped project beside it
#   (pokechamps/build -> TF_VAR_build_project_id), for stages that grant
#   another project's accounts access.
# Sets the step output `bootstrapped` to true or false: a project without
# bootstrap/ci.env hasn't been bootstrapped, and its job has nothing to do.
set -euo pipefail

project=${1:?usage: ci-env.sh <project folder>}
out=${GITHUB_ENV:-/dev/stdout}
result=${GITHUB_OUTPUT:-/dev/stdout}

if [ ! -f "$project/bootstrap/ci.env" ]; then
  echo "$project has no bootstrap/ci.env: not bootstrapped, skipping"
  echo "bootstrapped=false" >> "$result"
  exit 0
fi

grep -E '^[A-Z_]+=' "$project/bootstrap/ci.env" >> "$out"
echo "TF_VAR_project_id=$(sed -n 's/^GCP_PROJECT_ID=//p' "$project/bootstrap/ci.env")" >> "$out"

for file in "$(dirname "$project")"/*/bootstrap/ci.env; do
  name=$(basename "$(dirname "$(dirname "$file")")" | tr '-' '_')
  echo "TF_VAR_${name}_project_id=$(sed -n 's/^GCP_PROJECT_ID=//p' "$file")" >> "$out"
done
echo "bootstrapped=true" >> "$result"
