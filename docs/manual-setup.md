# Set up by hand

What was configured in a console or on a workstation rather than in this
repository's Terraform or workflows: the steps a person repeats to build the
same setup again, and the settings to check when something behaves
unexpectedly. Values that are secrets or that identify a person (billing
account ids, email addresses, account names) are not written here.

## Google Cloud

### Accounts and billing

- One Google account owns the infrastructure: the organisation-less
  projects below, their billing and the Terraform runs from a workstation.
  It has 2-step verification on. No other Google account holds a role on
  them.
- One billing account (personal, EUR) pays for every project. Its id is
  passed to a bootstrap as `TF_VAR_billing_account_id`, never committed.

### Bootstrapping a project

Each `<project>/<environment>/bootstrap/` stage is applied once from a
workstation (`tools/bootstrap <project>/<environment>`; the script's header
lists the variables to set, `TF_VAR_billing_account_id` and
`TF_VAR_github_owner_id` among them). It creates the project, the Terraform
and read-only plan service accounts, the state bucket and the GitHub Actions
identity provider, moves its own state into the bucket and writes
`backend.tf` and `ci.env`, which are committed. Done for `pokechamps/prod`
and `pokechamps/build`.

### Production's data store

- **The S3 key for the data bucket is made by hand**, so it never enters
  Terraform state: Cloud Storage → Settings → Interoperability → an HMAC key
  for the `pokechamps-app` service account (prod project). Its access key and
  secret are added as a new version of the Secret Manager secret
  `pokechamps-s3` as `{"access-key": "...", "secret-key": "..."}`. External
  Secrets copies it into the cluster. Rotating it: a new key, a new secret
  version, then delete the old key.
- **The first data was copied from the local store**, then checked byte for
  byte (`pokechamps` repository: `research/platform_check/prod_store.sh copy
  --apply`, then `verify`).

### Cloud Build (the `build` project)

- **The GitHub connection is made in the console**: Cloud Build →
  Repositories (2nd gen) → Create host connection, region `europe-west1`,
  name `github-aka-org`, authorised through the Google Cloud Build GitHub App
  installed on the `aka-org` organisation for the `pokechamps` repository
  only. Then "Link repository": `aka-org/pokechamps`, which Cloud Build names
  `aka-org-pokechamps`. The trigger itself is Terraform
  (`pokechamps/build/pipeline`) and points at that linked repository.
- **A release build waits for approval**: Cloud Build → History (region
  `europe-west1`) → the pending build → Approve, or
  `gcloud builds approve BUILD_ID --project <build project> --region europe-west1`.
  GitHub shows the build's status but can't approve it.

### Cluster access from a workstation

`gcloud container clusters get-credentials prod-eu --location europe-west1
--dns-endpoint --project <prod project>` (the control plane has no public
IP; the DNS endpoint is reached with IAM). Needs `gke-gcloud-auth-plugin`
from the Google Cloud SDK on `PATH`.

### After a release that changes how data is computed

The pipeline deploys code; data the jobs publish is recomputed by running
the jobs (`kubectl --context <prod context> -n pokechamps create job
--from=cronjob/pokechamps-<job> pokechamps-<job>-manual`), one at a time,
teams before reports. A change to how reports are written also needs the
published reports written again: `pokechamps` repository,
`research/platform_check/republish_reports.sh prod [--apply]`.

## GitHub (organisation `aka-org`)

### The automation App

- **`aka-org-automation`**, a GitHub App owned by the organisation, opens
  pull requests for `tools/ghpr`. Repository permissions: Pull requests
  read and write, Checks read, Contents read, Metadata read. Installed on
  the organisation's repositories that receive pull requests from it.
- Its App id and private key live on the workstation that runs `ghpr`
  (`~/.config/aka-org/github-app.env`), never in a repository. Branches
  are pushed with that workstation's SSH key, not the App.

### Organisation and repository settings

- **Merging: rebase only** (merge commits and squash off), on every
  repository. Stacked pull requests don't survive a rebase merge: each pull
  request starts from `main`.
- **Rulesets on `main`**: no force push, no deletion, changes through a pull
  request. GitHub enforces rulesets on public repositories on the Free plan;
  on a private one (`pokechamps`) they are saved but not enforced until the
  organisation moves to Team. The organisation and each repository were
  set up by the same steps.
- **GitHub environments** gate this repository's Terraform applies: each
  project's apply job runs in an environment whose required reviewer approves
  it (`.github/workflows/terraform.yml`).
- **Dependabot**: security updates on, through the organisation's code
  security configuration; Advanced Security features are unavailable to the
  private repository on the Free plan.
- **Tags**: a release tag (`vX.Y.Z`) is created by the shared
  `changelog-release.yml` workflow from the changelog, not by hand.

### Terraform registry

The public module repositories (`terraform-google-project`, `-network`,
`-compute`, `-gke`) are published on registry.terraform.io, connected
through the registry's GitHub integration; a new `vX.Y.Z` tag is picked up
by the registry by itself.

## Cloudflare

- **Account**: signed in with the same Google account as Google Cloud, and
  also given a Cloudflare password of its own and Cloudflare's own
  two-factor (an authenticator app; backup codes kept outside the phone).
  Email is not a second factor: it is the same Google account.
- **`vgcrival.com`**, registered at Cloudflare Registrar (personal
  registrant, contact details redacted): auto-renew on, registrar lock on,
  DNSSEC enabled (the DS record is added by the registrar itself).
  Multi-signer DNSSEC and multi-provider DNS stay off: one DNS provider.
- **No DNS records and no zone settings yet**: the records, the TLS mode
  and HTTPS settings come with the step that puts the site on the domain,
  and are to be written here then.
