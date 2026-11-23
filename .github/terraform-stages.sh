#!/usr/bin/env bash
# Plans or applies the stages of one project that have something to do,
# running independent chains of stages side by side. Called by
# terraform-project.yml's plan and apply jobs, after ci-env.sh, Terraform
# and the Google credentials are set up.
#
#   .github/terraform-stages.sh plan|apply
#
# Reads from the environment:
#   PROJECT        the project's folder (pokechamps/prod)
#   CHAINS         its stages as chains, separated by "|"; each chain lists
#                  stages in the order they are applied, each stage reading
#                  what an earlier one in its chain made (by a data source
#                  or a name); stages in different chains read nothing of
#                  each other's ("shared edge | eu/cluster eu/platform")
#   BASE, HEAD     the commits compared to find what changed
#   EVERY          true: every stage runs (a manual run, a change to a
#                  file every stage reads, a base this checkout lacks)
#   VALIDATE_ONLY  plan only: stages validated, not planned
#                  (space-separated)
#   TF_STATE_BUCKET  plan only: the project's state bucket (from ci-env.sh)
#
# Which stages run: a stage runs when a file under its folder changed, or
# when a stage before it in its chain runs (it may read what that one
# changes), or when EVERY is true. A chain with no stage to run is left
# out. With STAGES_DRY_RUN=1 the script prints the stages each chain would
# run and exits, without Terraform.
#
# Each chain runs in the background, its stages in order, stopping at the
# first stage that fails; its output is kept in a file and printed, one
# log group per chain, once every chain is done, so the log reads chain by
# chain. Exits non-zero when any chain failed.
set -uo pipefail

mode=${1:?usage: terraform-stages.sh plan|apply}
case "$mode" in plan|apply) ;; *) echo "unknown mode: $mode" >&2; exit 2 ;; esac
: "${PROJECT:?}" "${CHAINS:?}"
EVERY=${EVERY:-false}

# The files changed between BASE and HEAD, or nothing to compare when
# every stage runs anyway.
changed_files=""
if [ "$EVERY" != true ]; then
  changed_files=$(git diff --name-only "${BASE:?}" "${HEAD:?}") || exit 1
fi

# Picks, from one chain, the stages to run: from the first stage with a
# change onwards.
pick() {
  local on=$EVERY stage picked=()
  for stage in $1; do
    if [ "$on" != true ] && grep -q "^$PROJECT/$stage/" <<<"$changed_files"; then on=true; fi
    [ "$on" = true ] && picked+=("$stage")
  done
  echo "${picked[*]:-}"
}

# The plan of one stage, as the read-only account.
plan_stage() {
  local stage=$1 out
  # only a missing state skips the plan; any other error fails the stage
  if ! out=$(gcloud storage objects describe "gs://$TF_STATE_BUCKET/$stage/default.tfstate" 2>&1 > /dev/null); then
    if grep -qiE "not found|404|no urls matched" <<<"$out"; then
      # Terraform's GCS backend writes a lock to create a missing state (in
      # `init`, even with -lock=false), which the plan account can't: a
      # stage with no state yet is validated without its backend, and its
      # first plan is the apply job's, in the run for main.
      terraform -chdir="$PROJECT/$stage" init -input=false -backend=false || return 1
      terraform -chdir="$PROJECT/$stage" validate || return 1
      echo "validated only: $stage has no state yet; its first plan is shown by the apply job, in the run for main"
      return 0
    fi
    echo "$out" >&2
    return 1
  fi
  terraform -chdir="$PROJECT/$stage" init -input=false || return 1
  terraform -chdir="$PROJECT/$stage" validate || return 1
  case " ${VALIDATE_ONLY:-} " in
    *" $stage "*) echo "validated only: its plan is shown by the apply job, in the run for main" ;;
    # -lock=false: the plan account can't write the state's lock.
    *) terraform -chdir="$PROJECT/$stage" plan -input=false -lock=false || return 1 ;;
  esac
}

apply_stage() {
  local stage=$1
  terraform -chdir="$PROJECT/$stage" init -input=false || return 1
  terraform -chdir="$PROJECT/$stage" apply -input=false -auto-approve || return 1
}

run_chain() {
  local stage
  for stage in $1; do
    echo "=== $PROJECT/$stage"
    if ! "${mode}_stage" "$stage"; then
      echo "=== $PROJECT/$stage failed; the stages after it in this chain were not run"
      return 1
    fi
  done
}

chains=()
IFS='|' read -ra all <<<"$CHAINS"
for chain in "${all[@]}"; do
  chosen=$(pick "$chain")
  [ -n "$chosen" ] && chains+=("$chosen")
done

if [ "${STAGES_DRY_RUN:-}" = 1 ]; then
  for chain in "${chains[@]}"; do echo "$chain"; done
  exit 0
fi
if [ ${#chains[@]} -eq 0 ]; then
  echo "no stage of $PROJECT changed: nothing to $mode"
  exit 0
fi

logs=$(mktemp -d)
pids=()
for i in "${!chains[@]}"; do
  run_chain "${chains[$i]}" > "$logs/$i.log" 2>&1 &
  pids+=($!)
done

status=0
for i in "${!chains[@]}"; do
  wait "${pids[$i]}"; rc=$?
  echo "::group::$PROJECT: ${chains[$i]}$([ $rc -eq 0 ] || echo ' (failed)')"
  cat "$logs/$i.log"
  echo "::endgroup::"
  [ $rc -eq 0 ] || { echo "::error::$PROJECT: ${chains[$i]} failed"; status=1; }
done
exit $status
