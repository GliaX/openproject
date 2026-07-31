# openproject

Infrastructure-as-code for Glia's OpenProject deployment at **`project.glia.org`**.

> **Upgrading or troubleshooting?** Read **[OPERATIONS.md](OPERATIONS.md)** first — it has the
> architecture, the upgrade runbook, and the non-obvious gotchas of this setup
> (root user, SECRET_KEY_BASE check, probe Host header, ssl-redirect, Recreate
> strategy, helm recovery, etc.).

This repo packages OpenProject as a thin local Helm chart (Helm-as-Code,
matching `GliaX/helm-erpnext`) and ships a CI pipeline that deploys it to the
Glia DigitalOcean Kubernetes (DOKS) cluster. **Secrets live in GitHub Actions
secrets** — the repo is intentionally public and contains no plaintext secrets.

| | |
|---|---|
| **Release / namespace** | `openproject` / `openproject` |
| **App version (image)** | OpenProject **17.6.0** (`ghcr.io/gliax/openproject:17.6.0`) |
| **Site** | `project.glia.org` |
| **Cluster** | DOKS `do-tor1-k8s-glia1` (ingress `nginx`, issuer `letsencrypt-prod`) |
| **Database** | DigitalOcean managed PostgreSQL (external `DATABASE_URL`) |
| **Customisation** | `openproject-meeting_markdown_export` plugin (bundled in the image) |

## Layout

```
openproject/
├── Chart.yaml                    # local thin chart (appVersion 17.0.4)
├── values.yaml                   # Glia config — SECRET-FREE
├── values.secret.example.yaml    # documents the secret shape (no values)
├── templates/                    # deployment / service / ingress / pvc / configmap
├── Dockerfile                    # upstream image + markdown-export plugin
├── Gemfile.plugins               # plugin declaration
├── Gemfile.lock                  # locked deps (for the build)
└── .github/workflows/
    ├── build-image.yml           # builds ghcr.io/gliax/openproject (GITHUB_TOKEN)
    └── deploy.yml                # secrets → K8s Secret → helm upgrade
```

## Secrets (GitHub Actions → Kubernetes)

This repo is **public**, so all secrets are stored as GitHub Actions **repo
secrets** and reconciled into the `openproject-secrets` Kubernetes Secret by
`deploy.yml` at deploy time:

| GitHub secret | K8s Secret key | Used as |
|---|---|---|
| `DATABASE_URL` | `DATABASE_URL` | env `DATABASE_URL` |
| `SECRET_KEY_BASE` | `SECRET_KEY_BASE` | env `OPENPROJECT_SECRET_KEY_BASE` |
| `ENTERPRISE_TOKEN_RB` | `enterprise_token.rb` (file) | mounted at `/app/app/models/enterprise_token.rb` |
| `DIGITALOCEAN_ACCESS_TOKEN` | — (CI only) | `doctl` kubeconfig for deploy |

`enterprise_token.rb` is a third-party "free enterprise mode" shim that
unlocks OpenProject's enterprise features; it is kept out of the public repo
and mounted read-only into the pod from the Secret.

### One-time: set the repo secrets

```bash
gh secret set DATABASE_URL              --repo GliaX/openproject   # postgresql://...
gh secret set SECRET_KEY_BASE           --repo GliaX/openproject
gh secret set ENTERPRISE_TOKEN_RB       --repo GliaX/openproject < enterprise_token.rb
gh secret set DIGITALOCEAN_ACCESS_TOKEN --repo GliaX/openproject
```

## Deploy / upgrade

Pushing to `main` runs `deploy.yml`, which:

1. fetches a short-lived kubeconfig via `doctl`,
2. applies the `openproject-secrets` Secret (idempotent), then
3. runs `helm upgrade --install openproject . -n openproject`.

Manual deploy (with kubeconfig already on PATH):

```bash
helm upgrade --install openproject . --namespace openproject --create-namespace
```

## DNS cutover (once, manual)

`project.glia.org` historically pointed at `auth.emlondon.ca` (the old Docker
host). To serve from the cluster, point the record at the ingress LB
(`office.emlondon.ca`, as all other `*.glia.org` services do). cert-manager
then issues the TLS certificate via `letsencrypt-prod`. Until the cutover, the
Ingress exists but its certificate is pending.

```bash
# After cutover, watch TLS get issued:
kubectl -n openproject get certificate
```

## Backups

- **Database:** snapshot the DigitalOcean managed PostgreSQL database
  (`openproject_pool`) from the DO console / `doctl`.
- **Assets:** the `openproject-assets` PVC (uploaded files, ~38 Mi). Snapshot
  the underlying DigitalOcean block volume.

## Image build & version drift

`build-image.yml` rebuilds `ghcr.io/gliax/openproject` from `Dockerfile`
(upstream `openproject/openproject:<ver>` + the plugin). The `FROM` tag is
**pinned** to a specific OpenProject release, and the build converges on the
upstream image's own `Gemfile.lock` (no lockfile is shipped in this repo), so
rails stays at the version OpenProject supports (e.g. 17.6.0 → rails 8.1.3).

To upgrade: bump the `FROM` tag in `Dockerfile`, `appVersion` in `Chart.yaml`,
and `image.tag` in `values.yaml` to the new OpenProject version, run the
`build-image.yml` workflow (or build locally with `write:packages`), and push.
The pod auto-runs `db:migrate` on boot. Always take a DB backup first
(see Backups).
