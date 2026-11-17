# gcp-infra

Google Cloud infrastructure for aka-org's projects, as Terraform, laid out `<project>/<environment>/<stage>/`. Also home to what the other aka-org repositories share: reusable GitHub Actions workflows (`.github/workflows/`) and helper scripts (`tools/`).

## Layout

```
<project>/<environment>/bootstrap/          the environment's Google Cloud project, Terraform's service account, state bucket, Actions identity
<project>/<environment>/<region>/<stage>/   what runs in one region: one Terraform root per stage, its state under its own prefix

pokechamps/build/bootstrap/                 the project pokechamps-build-<suffix>: where images are built and kept, for every environment
pokechamps/build/pipeline/                  the image registry and Cloud Build's service account
pokechamps/prod/bootstrap/                  the project pokechamps-prod-<suffix>
pokechamps/prod/shared/                     what production's regions share: network, image registry, data bucket, service accounts, the secret entry
pokechamps/prod/eu/cluster/                 production's GKE Autopilot cluster in europe-west1
pokechamps/prod/eu/platform/                what runs in that cluster before any app: External Secrets and its Secret Manager store
```

An environment is named by its role (`prod`, `dev`) and lives in a Google Cloud project of its own, created by its `bootstrap` stage: the project is the boundary for access, billing and mistakes. A project is not tied to a region, so an environment that runs in two regions keeps both in the one project, each in its own folder. Another environment is another folder and another project. What environments must share -- the image registry and the pipeline that fills it, so each runs the same image and not a rebuild -- lives in a project of its own, `build`.

**Bootstrap** stages create what CI needs before it can run, so a person applies them once from a workstation with `tools/bootstrap <project>/<environment>` (its header lists what to set first). The other stages are applied by CI as the service account the bootstrap made.

**Every other stage goes through `.github/workflows/terraform.yml`**, project by project: a pull request plans each stage (the plan is in the run's log) and a merge to `main` applies them in order -- the `build` project first, then `prod` -- each after its GitHub environment's reviewer approves. A pull request's run acts as a read-only account; only runs for `main` can act as a project's own Terraform service account. The read-only account has no access to Secrets inside a cluster, so a stage made of Helm releases (`eu/platform`) is validated on a pull request and planned only in the run that applies it.

**What CI needs to act in a project is a file, not a setting**: each bootstrap writes `<project>/<environment>/bootstrap/ci.env` (the project's id, its two service accounts, its identity provider, its state bucket), committed beside `backend.tf`. They are names, not secrets -- what protects a project is that Google accepts its Terraform account only from this repository's `main`.

**No secret is kept in Terraform state or in this repository**: providers authenticate from the environment, the billing account id and similar values arrive as `TF_VAR_*` variables, and secret values are added to Secret Manager by hand.

## Tools

| Script | What it does |
|---|---|
| `tools/bootstrap` | Applies an environment's bootstrap stage from a workstation and moves its state into the bucket it created (`tools/bootstrap pokechamps/prod`). |
| `tools/ghpr` | Pushes the current work branch of a checkout and opens its pull request as the `aka-org-automation` GitHub App (`ghpr open DIR --title ...`), or lists the branch's check runs (`ghpr checks DIR`). Never pushes a default branch, merges, tags or force-pushes. Its docstring covers the App's settings file and permissions. |

## Shared workflows

Reusable GitHub Actions workflows the other aka-org repositories call (`uses: aka-org/gcp-infra/.github/workflows/<file>@main`), so each check is written once. A change here reaches every caller at its next run.

| Workflow | What it does | Called by |
|---|---|---|
| `terraform-module-ci.yml` | `terraform fmt`, `validate` and `terraform test` on the lowest and newest Google provider the module allows, TFLint, and a check that the README's generated tables match the code | each `terraform-google-*` module, on pull requests, weekly and before a release |
| `changelog-release.yml` | Tags and releases the newest version in the caller's `CHANGELOG.md` if it isn't out yet | each `terraform-google-*` module, on pushes to `main` |
