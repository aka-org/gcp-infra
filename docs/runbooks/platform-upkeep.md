# Keep the platform's versions current

The versions this repository pins or lets Google choose: the Terraform CLI,
its providers and the aka-org modules, GKE, the External Secrets chart, and
the GitHub Actions the workflows use. The app's own dependencies and
runtimes are the app repository's runbooks
(`aka-org/pokechamps`: `docs/runbooks/dependency-updates.md`,
`docs/runbooks/runtime-upgrade.md`), which also cover the Helm CLI that
deploys the app (pinned in its `cloudbuild*.yaml` and `checks.yml`).

## When

- **The quarterly look** (January, April, July, October): the Check below,
  every item, in one pull request per kind of change.
- **GKE announces a minor upgrade or an end of support** for the running
  version (the GKE release notes, or an email to the project's owner):
  the GKE part, before the upgrade's date.
- **A provider or chart release fixes a security issue**, or a resource
  this repository needs exists only in a newer version.

## Impact

None while checking. A provider, module or chart change takes effect on
its stage's apply, after the `prod` (or `build`) reviewer approves; a GKE
minor upgrade restarts every node in the daily maintenance window
(03:00-07:00 UTC), which restarts the app's pods and any job running then
(the jobs start over: the app's `docs/modelling/platform.md`, "Jobs the
cluster stops").

## Check

Read-only, from a checkout of `main`, with the Google Cloud SDK on `PATH`
(`export PATH=$HOME/google-cloud-sdk/bin:$PATH`).

**Terraform CLI** -- pinned in three places, kept equal:

    grep -rn -E 'terraform_version|TERRAFORM_VERSION' .github/workflows
    gh api repos/hashicorp/terraform/releases/latest -q .tag_name

**Providers** -- each stage's `.terraform.lock.hcl` holds the exact
version CI installs; `main.tf`'s `required_providers` the range allowed:

    for f in $(git ls-files '*/.terraform.lock.hcl'); do echo "== $f"; grep -A1 '^provider' "$f" | grep -o '"[^"]*"' | paste - -; done
    for p in hashicorp/google hashicorp/helm cloudflare/cloudflare hashicorp/random hashicorp/local; do
      echo "$p $(curl -s https://registry.terraform.io/v1/providers/$p | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')"
    done

**The aka-org modules** -- each stage's `module` block pins a release:

    grep -rn -A1 'source *= *"aka-org/' --include=*.tf pokechamps | grep version
    for m in project network gke compute; do echo "$m $(gh api repos/aka-org/terraform-google-$m/releases/latest -q .tag_name 2>/dev/null)"; done

**GKE** -- the channel picks the version; this is what is running, what
comes next and what the cluster still calls that the next minor removes:

    gcloud container clusters describe prod-eu --location europe-west1 --project pokechamps-prod-6f7bca80 \
      --format="value(currentMasterVersion,releaseChannel.channel,maintenancePolicy.window)"
    gcloud container get-server-config --location europe-west1 --project pokechamps-prod-6f7bca80 \
      --flatten=channels --filter="channels.channel=REGULAR" --format="yaml(channels.defaultVersion,channels.validVersions)"
    kubectl --context prod-eu get --raw /metrics | grep '^apiserver_requested_deprecated_apis' | grep -v 'removed_release=""'

The last line lists each API the cluster was asked for since the control
plane last restarted that a named Kubernetes release removes; nothing
printed means nothing to move. (GKE's deprecation insights say the same in
the console's cluster page, under "Upgrade"; the project leaves the
Recommender API off, so they are not read from `gcloud`.)

**The External Secrets chart** (`pokechamps/prod/eu/platform/main.tf`,
`helm_release` `external-secrets`):

    helm repo add external-secrets https://charts.external-secrets.io >/dev/null; helm repo update >/dev/null
    helm search repo external-secrets/external-secrets --versions | head -5
    grep -n -A1 'chart *= *"external-secrets"' pokechamps/prod/eu/platform/main.tf

**Actions** -- every `uses:` and the latest major of each:

    grep -rhn 'uses: [a-z]' .github/workflows | grep -v '\./' | sed 's/.*uses: //' | sort -u
    for a in actions/checkout hashicorp/setup-terraform google-github-actions/auth google-github-actions/setup-gcloud terraform-linters/setup-tflint; do
      echo "$a $(gh api repos/$a/releases/latest -q .tag_name)"
    done

plus the tool versions `terraform-module-ci.yml` takes as inputs
(`tflint_version`, `terraform_docs_version`):

    for r in terraform-linters/tflint terraform-docs/terraform-docs; do echo "$r $(gh api repos/$r/releases/latest -q .tag_name)"; done

## Fix

On a branch in a worktree off `main`; a pull request per kind of change,
each planned by CI before it is merged.

1. **Terraform CLI**: the version in `terraform.yml` (the `fmt` job),
   `terraform-project.yml` (`TERRAFORM_VERSION`) and
   `terraform-module-ci.yml` (`terraform_version`'s default), and on the
   workstation for `tools/bootstrap`. Every stage's `required_version` is a
   floor, left as it is unless the new release's features are used.

2. **Providers within their range**: per stage,

       terraform -chdir=<stage> init -upgrade -backend=false
       terraform -chdir=<stage> providers lock -platform=linux_amd64 -platform=darwin_arm64

   and the changed `.terraform.lock.hcl` committed. The pull request's plan
   (in its run's log) must show no change to any resource; a provider that
   wants to change resources is read in its changelog before merging.
   **A provider's major** (google 8, cloudflare 6, helm 4) is its own pull
   request: its upgrade guide read, the range in every stage's
   `required_providers` and in each module's `versions.tf` moved together
   (a module is released first, `changelog-release.yml`), and its plan
   reviewed resource by resource.

3. **A module's new release**: its `version` in each stage that uses it;
   the release's `CHANGELOG.md` read; the plan reviewed. The module's own
   CI already tested it on the lowest and newest Google provider it allows.

4. **GKE**: the cluster follows the `REGULAR` channel and upgrades itself
   in the maintenance window; nothing is pinned. Before a minor upgrade
   reaches it, whatever the metric above names
   is moved off the removed API (in the app's chart, or a chart here), and
   released before the upgrade's date. To hold an upgrade that can't be
   ready in time, a maintenance exclusion (up to 90 days, no minor
   upgrades) -- the GKE module has no input for it, so it is set with
   `gcloud` and recorded in `../manual-setup.md` until it ends:

       gcloud container clusters update prod-eu --location europe-west1 --project pokechamps-prod-6f7bca80 \
         --add-maintenance-exclusion-name hold-<minor> \
         --add-maintenance-exclusion-start <YYYY-MM-DDT00:00:00Z> \
         --add-maintenance-exclusion-end <YYYY-MM-DDT00:00:00Z> \
         --add-maintenance-exclusion-scope no_minor_upgrades

   The workstation's `kubectl` is kept within one minor of the cluster
   (`gcloud components update kubectl`).

5. **The External Secrets chart**: `version` in
   `pokechamps/prod/eu/platform/main.tf`; the chart's release notes read
   for CRD changes (a new `apiVersion` for `ExternalSecret` or
   `SecretStore` means the app's `ExternalSecret`s and this stage's
   `charts/secret-store` move with it). The stage is only validated on a
   pull request (the read-only account can't read Helm's release records),
   so its real plan is read in the applying run before approving it.

6. **Actions**: each `uses:` moved to the new major in every workflow
   together; the release notes read for changed inputs. The shared
   workflows (`terraform-module-ci.yml`, `changelog-release.yml`) reach
   every caller at its next run: one module's pull request (any change)
   or a manual run of its CI shows the new versions work before the other
   modules depend on it.

## Verify

    gh run list --workflow terraform.yml --limit 3           # the merge's apply succeeded
    gh run view <run id> --log | grep -E "Plan:|No changes"
    kubectl --context prod-eu get externalsecrets -A           # every one SecretSynced (after a chart change)
    gcloud container clusters describe prod-eu --location europe-west1 --project pokechamps-prod-6f7bca80 --format="value(currentMasterVersion,currentNodeVersion)"

After a GKE upgrade: the app's `research/platform_check/cluster_review.sh
prod-eu pokechamps` shows every pod Ready and the next jobs complete.

## Related

`../manual-setup.md` (the cluster access, the bootstrap), the README
("Layout", "Shared workflows"), the GKE module's README
(`aka-org/terraform-google-gke`: `release_channel`,
`maintenance_start_time`), the app's `docs/modelling/platform.md`.
