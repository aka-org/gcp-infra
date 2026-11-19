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
- **Deploying without a release** (a configuration change only): Cloud
  Build → Triggers → `pokechamps-deploy` → Run, with `_VERSION` set to a
  released version (`0.2.0`), or `gcloud builds triggers run
  pokechamps-deploy --project <build project> --region europe-west1
  --branch main --substitutions _VERSION=0.2.0`; then approve it like a
  release. The trigger is Terraform (`pokechamps/build/pipeline`); what it
  runs is the app repository's `cloudbuild-deploy.yaml`.

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
  it (`.github/workflows/terraform.yml`). Only a project something changed
  in asks; the others' jobs are skipped.
- **Required checks** on this repository's `main`: `fmt`, `plan-build /
  plan`, `plan-prod / plan`. The Terraform workflow runs on every pull
  request so they always report: a project nothing changed in reports its
  plan as skipped, which passes.
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
- **The zone is Terraform** (`pokechamps/prod/edge`): its DNS records, TLS
  mode, HTTPS settings and rules. What stays by hand is below; a record or
  setting made in the dashboard instead would be overwritten (a setting) or
  left unmanaged (a record), so changes go through that stage.

### API tokens for Terraform

Two account API tokens (My Profile → API Tokens → Create Custom Token), each
limited to the zone `vgcrival.com` (Zone Resources: Include · Specific zone):

- **`gcp-infra-plan`**, read-only: Zone · Zone · Read, Zone · DNS · Read,
  Zone · Zone Settings · Read, Zone · Config Rules · Read, Zone · Single
  Redirect · Read (the dashboard's names for the zone's dynamic redirects).
  Stored as the **repository** secret `CLOUDFLARE_API_TOKEN` of
  `aka-org/gcp-infra` (Settings → Secrets and variables → Actions); plans
  read it.
- **`gcp-infra-apply`**, the same permissions with Edit in place of Read
  (Zone · Zone stays Read). Stored as the **`prod` environment's** secret
  `CLOUDFLARE_API_TOKEN` (Settings → Environments → prod); an apply runs in
  that environment, where it takes the repository secret's place.

Both exist before a pull request touching the edge stage is opened: its plan
needs the read-only one. Rotating one: a new token, the secret replaced, the
old token deleted.

### The site's certificate (Cloudflare Origin CA)

Cloudflare reaches the load balancer over HTTPS and checks its certificate
(Full (strict)); the load balancer presents a certificate issued by
Cloudflare's Origin CA, which only Cloudflare trusts. Made by hand so its
private key never enters Terraform state:

1. SSL/TLS → Origin Server → Create Certificate: "Generate private key and
   CSR with Cloudflare", key type RSA (2048), hostnames `vgcrival.com` and
   `*.vgcrival.com`, validity 15 years, format PEM.
2. Save the certificate and the private key to two files (`origin.crt`,
   `origin.key`); the key is shown once.
3. Add them as a new version of the Secret Manager secret
   `pokechamps-web-tls` (prod project; the empty entry is Terraform's,
   `pokechamps/prod/shared`):
   `jq -n --rawfile crt origin.crt --rawfile key origin.key '{"tls.crt": $crt, "tls.key": $key}' | gcloud secrets versions add pokechamps-web-tls --project <prod project> --data-file=-`
4. Delete both files (`shred -u origin.crt origin.key`).

External Secrets copies it into the cluster as the Ingress's TLS Secret
(the app repository's `deploy/prod/web.yaml`); the load balancer picks up a
new version within the operator's refresh interval. Renewing: a new
certificate the same way, then revoke the old one in the same dashboard
page. It expires 15 years after issue.

### Proving the domain to Google (for the `cdn.` bucket)

Cloud Storage creates a bucket named after a domain only for an account
Google knows owns it. Done once, with the infrastructure's Google account:

1. Google Search Console → Add property → **Domain** → `vgcrival.com`; copy
   the TXT value it shows (`google-site-verification=...`), don't verify
   yet.
2. Set it as `google_site_verification` in `pokechamps/prod/edge` (a pull
   request: the value is public, as every DNS record is) and let the apply
   add the record.
3. Back in Search Console: Verify.
4. Settings → Users and permissions → Add user: production's Terraform
   service account (`GCP_SERVICE_ACCOUNT` in `pokechamps/prod/bootstrap/ci.env`),
   permission **Owner**. Terraform creates the bucket as that account.

The TXT record stays: Google checks it again from time to time.
