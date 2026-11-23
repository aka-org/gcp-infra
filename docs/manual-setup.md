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
IP; the DNS endpoint is reached with IAM), then `kubectl config
rename-context gke_<prod project>_europe-west1_prod-eu prod-eu`: the app
repository's runbooks name the context `prod-eu`. Needs
`gke-gcloud-auth-plugin` from the Google Cloud SDK on `PATH`. The rest of
the workstation (tools, credentials, a check of each) is the app
repository's `docs/development.md` and `ops/doctor.sh`.

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

Two more addresses, the same way (step 2 for each, the same destination or
its own `+` tag):

- `feedback@` -- the site's Feedback link offers it beside Discord, for
  people without a Discord account;
- `social@` -- the address an account of the site's is created with (the
  X account, when posting there starts), so no account depends on a
  personal address.

Test each as above.

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

## Discord

The site's community server: announcements posted by the reports job,
feedback and bug reports, talk about the meta. Owned by the operator's own
Discord account (any account can own a server; ownership can be
transferred later). Two-factor authentication on that account first: User
Settings → My Account → Enable Authenticator App.

### The server

1. Create: the **+** in the server list → Create My Own → For a club or
   community. Name: the site's name; icon: the site's icon
   (`web/static/favicon.svg` rendered at 512 px).
2. Community: Server Settings → Enable Community → follow the steps
   (verified email required, explicit media scanned for all members, a
   rules channel and a community updates channel). Community is what
   allows an announcement channel and the safety settings below.
3. Channels and categories (Server Settings → or right-click the server):
   - **Information:** `#rules` (the rules channel chosen in step 2),
     `#announcements` (Create Channel → Announcement; only admins post),
     `#about` (what the site is, its links; only admins post);
   - **Talk:** `#general`, `#meta-talk`, `#teams`;
   - **Site:** `#feedback`, `#bugs` (pin a message with the template: the
     page's link, what happened, the device and browser).
   Delete the default channels the server came with that aren't above.
4. Roles (Server Settings → Roles): **Admin** (the owner already holds
   every permission), **Moderator** (Manage Messages, Timeout Members, Kick
   Members; nobody yet). @everyone: no permission to post in Information.
5. Safety (Server Settings → Safety Setup): verification level **Medium**
   (a verified email and registered 5+ minutes) or **Low** (a verified
   email); AutoMod's spam, mention-spam and commonly-flagged-words rules
   on (Discord names them "Block Suspected Spam Content", "Block Mention
   Spam" and "Block Commonly Flagged Words"; its menus get renamed now and
   then -- the three are the ones to turn on), alerts to a channel only
   Admin sees (`#mod-log`, private).
6. Invite: on `#about` → Invite People → Edit invite link → Expire After:
   **Never**, Max Number of Uses: **No limit**. That link is the one the
   site's footer and Feedback link use (not a secret; given to the app in
   its values).
7. Your nickname here (right-click your name → Edit Server Profile): the
   name visitors see when you answer, and a role marking you as the
   developer.

Check: open the invite in a private window logged in as another account (or
ask someone): it lands on `#rules`, `#announcements` is readable but not
writable, `#feedback` writable.

### The announcements webhook

The reports job posts each card through a webhook on `#announcements`.

1. `#announcements` → Edit Channel → Integrations → Webhooks → New
   Webhook. Name: the site's name; avatar: its icon. Copy Webhook URL.
2. Add the URL as a version of the Secret Manager secret
   `pokechamps-discord-webhook` (prod project; the empty entry is
   Terraform's, `pokechamps/prod/shared`), without it touching shell
   history or a file:
   `read -rs URL && printf %s "$URL" | gcloud secrets versions add pokechamps-discord-webhook --project <prod project> --data-file=- && unset URL`
   (paste the URL, Enter).
3. Never paste the URL anywhere else: anyone holding it can post to the
   channel.

Check: `gcloud secrets versions list pokechamps-discord-webhook --project
<prod project>` shows one enabled version. A post through it is checked
when the app posts its first card (in dry run until the operator switches
it on).

Replacing it (leaked, or the channel recreated): delete the webhook in the
channel's Integrations, make a new one, add it as a new version (step 2),
disable the old version (`gcloud secrets versions disable <n> ...`).
External Secrets picks up the new value within its refresh interval.

## Bluesky

The site's account, which the reports job posts the announcements to (the
pokechamps repo's `reports/bluesky.py`; its runbook
`docs/runbooks/discord-posts.md`, "Bluesky").

1. Sign up at bsky.app with `social@` (the domain's address for the site's
   accounts, above); handle `vgcrival.bsky.social` (the pokechamps repo's
   `deploy/prod/reports.yaml` names it as `BLUESKY_HANDLE`; change both
   together). Profile: the site's name, its icon as the avatar, the site
   card as the banner, the site's address as the website.
2. Settings → Privacy and security → Two-factor authentication: on (an
   email code).
3. Settings → Privacy and security → App passwords → Add: name it after
   the reports job; no access to direct messages. Copy the password it
   shows once.
4. Add it as a version of the Secret Manager secret
   `pokechamps-bluesky-app-password` (prod project; the empty entry is
   Terraform's, `pokechamps/prod/shared`), without it touching shell
   history or a file:
   `read -rs P && printf %s "$P" | gcloud secrets versions add pokechamps-bluesky-app-password --project <prod project> --data-file=- && unset P`

Check: `gcloud secrets versions list pokechamps-bluesky-app-password
--project <prod project>` shows one enabled version; the runbook's
session check answers with the account's handle. Posts go out once the
operator switches `ANNOUNCE_BLUESKY` from `dry` to `on`.

The domain as the handle (`@vgcrival.com`): Bluesky → Settings → Account →
Handle → "I have my own domain" → DNS shows a TXT record
(`_atproto.<domain>`, `did=did:plc:...`). Its DID is `pokechamps/prod/edge`'s
`bluesky_did` (Terraform, not by hand); once applied, press Verify in
Bluesky. The pokechamps repo's `BLUESKY_HANDLE` names the account by its
DID, which a handle change never breaks.

Replacing the app password (leaked or revoked): add a new one (step 3), add
it as a new version (step 4), delete the old one in Bluesky and disable its
version (`gcloud secrets versions disable <n> ...`).

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
  Redirect · Read (the dashboard's names for the zone's dynamic redirects),
  Zone · Zone WAF · Read (the custom firewall rules).
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
