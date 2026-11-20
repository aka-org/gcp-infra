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
  --apply`, then `verify`), into a bucket named after the project; it moved
  to `cdn.vgcrival.com` when the site took its domain (`pokechamps`
  repository: `research/platform_check/move_bucket.sh copy --apply`, then
  `verify`, with the jobs' CronJobs suspended), and the first bucket was
  emptied by hand and removed.

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

### Production's alerts

The alert policies are Terraform (`pokechamps/prod/shared/alerts.tf`); the
email channel they send to is made by hand, so the address is in neither
this repository nor Terraform state. Before the first apply of those
policies (its plan fails while the channel doesn't exist):

1. Monitoring → Alerting → Edit notification channels → Email → Add new,
   in the prod project. Email: the address alerts go to (a `+` tag such as
   `name+vgcrival-alerts@gmail.com` lets a mail filter pick them out by
   recipient alone); display name **`vgcrival prod alerts`**, exactly: the
   stage finds the channel by that name (its `alert_channel_name`
   variable).
2. The bootstrap stage gives Terraform's service account the two
   Monitoring roles the policies need (`roles/monitoring.alertPolicyEditor`,
   `roles/monitoring.notificationChannelViewer`,
   `roles/logging.configWriter` for the policy matching log entries, and
   `roles/monitoring.uptimeCheckConfigEditor` for the uptime check; for the billing export
   and budget, `roles/bigquery.dataOwner` and the billing account roles
   below). Bootstrap stages aren't
   applied by CI: once the pull request adding them is merged, re-run
   `tools/bootstrap pokechamps/prod` from `main` while the `prod` apply waits
   for its approval, then approve it.

Every alert email's subject starts with `[vgcrival prod]`. Changing the
address: edit the channel; no Terraform change.

### Email for the domain (Cloudflare Email Routing)

`privacy@vgcrival.com` (the address the site's Privacy page gives) forwards
to the operator's inbox through Cloudflare Email Routing. Set up by hand,
not in the `edge` stage: a forwarding rule holds the destination address,
which would otherwise be in this public repository's plan logs and in
state. Email → Email Routing, in the zone:

1. Destination addresses: the inbox (verified by the link Cloudflare emails;
   already verified when it is the Cloudflare account's own address). A `+`
   tag (`name+vgcrival-privacy@...`) lets a mail filter pick it out.
2. Routing rules → Custom addresses → `privacy` → Send to an email → that
   destination. The catch-all stays disabled: mail to any other address on
   the domain is refused.
3. Enable, letting Cloudflare add its records: three MX records
   (`route1/2/3.mx.cloudflare.net`), the SPF TXT record on the apex
   (`v=spf1 include:_spf.mx.cloudflare.net ~all`) and its DKIM key
   (`cf2024-1._domainkey`). Cloudflare keeps them locked for Email Routing,
   and the `edge` stage leaves records it didn't create alone.

Test: mail to `privacy@vgcrival.com` from another account arrives.

### Visit counts (Cloudflare Web Analytics)

The site counts page views with Cloudflare Web Analytics: a script in each
page reporting a view, without cookies or anything stored on the device.
The site (`vgcrival.com`) is set up by hand -- it is an account-level
resource, which this repository's zone-scoped tokens can't reach: Analytics
& Logs → Web Analytics → the site, on **manual** setup (the automatic
insertion never appeared in the pages). The app adds the script itself
where `CF_ANALYTICS_TOKEN` is set (the app repository's
`deploy/prod/web.yaml`; the token is public, it is in every page's HTML).
Read in the same dashboard, or through Cloudflare's GraphQL API
(`rumPageloadEventsAdaptiveGroups`).

### Billing export

The dataset `billing_export` (prod project) is Terraform
(`pokechamps/prod/shared/billing.tf`); switching the export on has no API,
so it is done by hand once that stage has applied: Billing → Billing export
→ BigQuery export → **Standard usage cost** → Edit settings → project
`pokechamps-prod-…`, dataset `billing_export` → Save. Rows arrive within
hours and cover the whole billing account from about that day on. The
monthly budget in the same file emails the alerts' channel and the billing
account's administrators at 50%, 90% and 100% of EUR 100; it replaced a
budget made by hand, deleted once this one appeared under Billing → Budgets
& alerts. Granting Terraform's account `roles/billing.costsManager` on the
billing account (bootstrap) needs a person with that account's billing
administration: re-run `tools/bootstrap pokechamps/prod`, as for the alerts.

### After a release that changes how data is computed

The pipeline deploys code; data the jobs publish is recomputed by running
the jobs by hand: the app repository's runbook `docs/runbooks/run-a-job.md`.

## GitHub (organisation `aka-org`)

### The automation App

- **`aka-org-automation`**, a GitHub App owned by the organisation, opens
  pull requests for `tools/ghpr`. Repository permissions: Pull requests
  read and write, Checks read, Contents read, Metadata read. Installed on
  the organisation's repositories that receive pull requests from it.
- Its App id and private key live on the workstation that runs `ghpr`
  (`~/.config/aka-org/github-app.env`), never in a repository. Branches
  are pushed with that workstation's SSH key, not the App.
- The same file's `REVIEWERS=` line names who `ghpr` asks to review each
  pull request it opens (comma-separated GitHub logins), so the pull
  requests show under github.com/pulls/review-requested. Set it by hand on
  the workstation.

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
needs the read-only one. Both were made with a one-year lifetime (created
2026-11-19, so they expire around 2027-11-19): an expired token fails the
edge stage's plan or apply with an authentication error. Rotating one: a new
token, the secret replaced, the old token deleted.

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
