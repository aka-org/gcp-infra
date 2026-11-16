# gcp-infra

Google Cloud infrastructure for aka-org's projects, as Terraform, laid out `<project>/<environment>/<stage>/`. Also home to what the other aka-org repositories share: reusable GitHub Actions workflows (`.github/workflows/`) and helper scripts (`tools/`).

## Layout

```
<project>/<environment>/<stage>/     one Terraform root per stage, its state under its own prefix
pokechamps/eu/bootstrap/             the environment's project, Terraform's service account, state bucket, Actions identity
```

Each environment lives in a Google Cloud project of its own, created by its `bootstrap` stage; another environment is another folder and another project, sharing nothing.

**Bootstrap** stages create what CI needs before it can run, so a person applies them once from a workstation with `tools/bootstrap <project>/<environment>` (its header lists what to set first). The other stages are applied by CI as the service account the bootstrap made.

**No secret is kept in Terraform state or in this repository**: providers authenticate from the environment, the billing account id and similar values arrive as `TF_VAR_*` variables, and secret values are added to Secret Manager by hand.

## Tools

| Script | What it does |
|---|---|
| `tools/bootstrap` | Applies an environment's bootstrap stage from a workstation and moves its state into the bucket it created (`tools/bootstrap pokechamps/eu`). |
| `tools/ghpr` | Pushes the current work branch of a checkout and opens its pull request as the `aka-org-automation` GitHub App (`ghpr open DIR --title ...`), or lists the branch's check runs (`ghpr checks DIR`). Never pushes a default branch, merges, tags or force-pushes. Its docstring covers the App's settings file and permissions. |

## Shared workflows

Reusable GitHub Actions workflows the other aka-org repositories call (`uses: aka-org/gcp-infra/.github/workflows/<file>@main`), so each check is written once. A change here reaches every caller at its next run.

| Workflow | What it does | Called by |
|---|---|---|
| `terraform-module-ci.yml` | `terraform fmt`, `validate` and `terraform test` on the lowest and newest Google provider the module allows, TFLint, and a check that the README's generated tables match the code | each `terraform-google-*` module, on pull requests, weekly and before a release |
| `changelog-release.yml` | Tags and releases the newest version in the caller's `CHANGELOG.md` if it isn't out yet | each `terraform-google-*` module, on pushes to `main` |
