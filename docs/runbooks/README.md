# Runbooks

What to do, step by step, for each operation on the platform. A runbook
lives in the repository whose things it operates:

- **Here** -- the cluster, the Cloudflare zone, tokens, certificates and
  keys, budgets: each Terraform stage's recurring operations.
- **The app's** (`aka-org/pokechamps`, `docs/runbooks/`) -- its jobs, data,
  releases and rollbacks, and the alerts' responses (every alert in
  `pokechamps/prod/shared/alerts.tf` links its runbook there).

One-time setup stays in [`../manual-setup.md`](../manual-setup.md). The
convention and the template (When, Impact, Check, Fix, Verify, Related;
steps as commands or scripts, a script that changes anything dry-run by
default with `--apply`) are the app repository's `docs/runbooks/README.md`.

None written here yet. To write when each is next needed, from
`../manual-setup.md`: rotating the Cloudflare API tokens (made 2026-11-19
for a year), renewing the Origin certificate, rotating the data bucket's
HMAC key.
