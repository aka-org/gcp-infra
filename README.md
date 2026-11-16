# gcp-infra

Google Cloud infrastructure for aka-org's projects, as Terraform, laid out `<project>/<environment>/<stage>/`. Also home to what the other aka-org repositories share: reusable GitHub Actions workflows (`.github/workflows/`) and helper scripts (`tools/`).

## Tools

| Script | What it does |
|---|---|
| `tools/ghpr` | Pushes the current work branch of a checkout and opens its pull request as the `aka-org-automation` GitHub App (`ghpr open DIR --title ...`), or lists the branch's check runs (`ghpr checks DIR`). Never pushes a default branch, merges, tags or force-pushes. Its docstring covers the App's settings file and permissions. |
