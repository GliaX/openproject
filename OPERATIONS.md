# Operations & Troubleshooting

Reference for upgrading and troubleshooting the Glia OpenProject deployment
(`project.glia.org`). Read this before upgrading or debugging — it captures
hard-won specifics of this setup that are not obvious from the chart alone.

## Current baseline (as of last session)

- **OpenProject 17.6.0**, image `ghcr.io/gliax/openproject:17.6.0`
  (upstream `openproject/openproject:17.6.0` + the
  `openproject-meeting_markdown_export` plugin; rails 8.1.3, hocuspocus v4.2.0).
- Deployed in namespace `openproject` on DOKS cluster **`k8s-glia1`**
  (kubeconfig context `do-tor1-k8s-glia1`).
- Pod healthy at `replicas=1`, memory limit 4Gi, `strategy: Recreate`,
  pinned to node `pool-f971mwbjk-372vs6`.
- TLS via cert-manager `letsencrypt-prod`, cert valid (renews automatically).

## Architecture at a glance

| Thing | Value |
|---|---|
| Cluster | DigitalOcean DOKS `k8s-glia1` (2 nodes: `pool-f971mwbjk-372vs6`, `-372vst`) |
| Public DNS | `*.glia.org` → `159.203.50.191` = `office.emlondon.ca` = ingress-nginx LoadBalancer |
| Ingress | class `nginx`; **cluster-direct** (NO reverse proxy on `auth.emlondon.ca`) |
| TLS | cert-manager, `cluster-issuer: letsencrypt-prod`, HTTP-01 |
| Database | DigitalOcean managed Postgres `db-postgresql-tor1-15038-…:25061/openproject_pool` (external; not in-cluster) |
| Image | `ghcr.io/gliax/openproject:<ver>` (public package) = upstream all-in-one + plugin |
| Secrets | GitHub Actions repo secrets → K8s Secret `openproject-secrets` (never in git) |
| Assets | PVC `openproject-assets` (RWO, `do-block-storage`, `helm.sh/resource-policy: keep`), node-pinned |
| Old Docker host | `auth.emlondon.ca` (`mail.emlondon.ca`, `174.138.112.166`) — the previous Docker deployment, now **OFF** |

The all-in-one image runs **puma + GoodJob (20 threads) + hocuspocus + memcached + apache + postfix** under one supervisord.

## The non-obvious rules (read before touching anything)

1. **The image MUST run as root.** The all-in-one entrypoint checks the external DB via `su postgres -c "psql …"` and runs supervisord as root. If the Dockerfile ends with `USER app`, the pod crash-loops with `su: Authentication failure` → `Unable to contact postgres`. Always finish the Dockerfile with `USER root`.
2. **17.6+ aborts on the default `SECRET_KEY_BASE`.** The image ships `SECRET_KEY_BASE=OVERWRITE_ME`; OpenProject 17.6.0 refuses to boot if it's still that value. Set **both** `OPENPROJECT_SECRET_KEY_BASE` **and** the raw `SECRET_KEY_BASE` from the Secret (the check reads the raw one). Both already wired in `templates/deployment.yaml`.
3. **Probes must send the Host header.** OpenProject validates the HTTP Host (from `OPENPROJECT_HOST__NAME`); a kubelet probe to the pod IP gets HTTP 400. `readinessProbe`/`livenessProbe` use `httpHeaders: [{name: Host, value: project.glia.org}]`.
4. **Disable ingress ssl-redirect.** ingress-nginx's default ssl-redirect 308's the cert-manager HTTP-01 challenge (which arrives over plain HTTP) → TLS never issues. `nginx.ingress.kubernetes.io/ssl-redirect: "false"` (OpenProject still forces HTTPS at the app layer).
5. **Memory: use ≥4Gi limit.** The all-in-one is memory-hungry; 2Gi ⇒ OOMKilled under load (the old Docker host had no limit).
6. **Use Deployment `strategy: Recreate`.** Single replica + RWO PVC: RollingUpdate tries two pods on the pinned node ⇒ `Insufficient memory` / Multi-Attach. Recreate kills the old pod first.
7. **Pin the image tag + converge on the upstream lockfile.** `FROM openproject/openproject:<ver>` (pinned; the `:17` tag is moving). Do NOT ship a `Gemfile.lock` — `bundle install` converges on the image's own lockfile so rails stays at the OpenProject-supported version.
8. **Keep `.helmignore`.** Helm has no default ignore; without it helm packages `.git/` and fails ("chart file … larger than 5242880") if any git object exceeds 5 MB.
9. **No concurrent helm operations.** Concurrent deploys (CI + manual, or multiple pushes) corrupt the release ("another operation is in progress" / pending-rollback). `deploy.yml` has a `concurrency` group; never run a local `helm` command while CI is deploying.
10. **Re-pushing the same tag won't re-pull.** With `IfNotPresent`, the node caches by tag. Either use a unique tag per build or `imagePullPolicy: Always` (currently `Always`).

## Upgrading OpenProject

```bash
# 1. Pick the target (latest stable on Docker Hub; -rc/dev are NOT stable)
curl -s 'https://hub.docker.com/v2/repositories/openproject/openproject/tags?page_size=100&ordering=last_updated' \
  | jq -r '[.results[].name | select(test("^(17|18)\\d*\\.\\d+\\.\\d+$"))] | sort_by(split(".")|map(tonumber))|last'
```

**2. Backup FIRST (and verify the dump is complete!).**

```bash
# DB — write to a FILE, do not pipe (piping can TRUNCATE; see Gotchas)
kubectl -n openproject exec deploy/openproject -- sh -c \
  'pg_dump --format=custom --no-owner "$DATABASE_URL" > /tmp/op.dump'
kubectl -n openproject cp deploy/openproject:/tmp/op.dump ./openproject-$(date +%F).dump
# VERIFY completeness — must list ALL ~170 tables, no "end of file" error:
pg_restore --list ./openproject-*.dump | grep -c 'TABLE DATA'   # expect ~171
pg_restore -f /tmp/check.sql --data-only ./openproject-*.dump   # must exit 0, no truncation

# Assets (PVC) — keep off-repo
kubectl -n openproject exec deploy/openproject -- tar cf - -C /var/openproject/assets . > ./assets.tar
```

**3. Build the new image** (needs a gh token with `write:packages`).

```bash
# Edit Dockerfile: FROM openproject/openproject:<NEW_VER>
# (ensure it still ends with USER root, has the build-dep apt line, no shipped Gemfile.lock)
docker build -t ghcr.io/gliax/openproject:<NEW_VER> .
docker push  ghcr.io/gliax/openproject:<NEW_VER>
```

**4. Update the chart:** `Chart.yaml` `appVersion` and `values.yaml` `image.tag` → `<NEW_VER>`.

**5. Deploy:** push to `main` (deploy.yml runs, concurrency-controlled, `--atomic --timeout 10m`) — the pod auto-runs `db:migrate` on boot. Watch:

```bash
kubectl -n openproject logs deploy/openproject | grep -iE 'migrat|Database setup|Booting Puma|exited'
curl -sS -o /dev/null -w '%{http_code}\n' https://project.glia.org/
```

If it fails, `helm uninstall openproject` + `helm install openproject . -n openproject` (the assets PVC and the app Secret/Cert survive — see Recovery), then restore the DB dump if migrations half-ran.

## Troubleshooting (symptom → fix)

| Symptom | Cause | Fix |
|---|---|---|
| `su: Authentication failure` / `Unable to contact postgres` | Image runs as non-root | End Dockerfile with `USER root` (rule 1) |
| `web`/`worker` `exit status 1`, `INSECURE SECRET_KEY_BASE DETECTED` | 17.6+ check; raw SECRET_KEY_BASE = `OVERWRITE_ME` | Set `SECRET_KEY_BASE` env from Secret (rule 2) |
| `OOMKilled` (exit 137), restart loop | memory limit too low | raise `resources.limits.memory` to ≥4Gi (rule 5) |
| Pod `0/1` forever; probe log `HTTP 400` | probe lacks Host header | `httpHeaders: Host: project.glia.org` (rule 3) |
| New pod `Pending: Insufficient memory` during upgrade | RollingUpdate + RWO PVC | `strategy: Recreate` (rule 6) |
| Certificate `Ready=False`, challenge `wrong status code '308'` | ssl-redirect intercepts ACME | `nginx.ingress.kubernetes.io/ssl-redirect: "false"` (rule 4) |
| Certificate `Ready=False`, challenge `wrong status code '404'` | DNS still pointing at old host / not propagated | confirm `dig project.glia.org` = `159.203.50.191`; wait for TTL (3h) |
| `UPGRADE FAILED: another operation … in progress` | concurrent/stuck helm op | see Recovery below |
| `chart file … larger than the maximum file size 5242880` | missing `.helmignore`; big file in tree | keep `.helmignore`; never put backups/binaries in the chart dir |

## Recovery: stuck/corrupted helm release

```bash
helm -n openproject history openproject      # look for pending-*/failed
helm -n openproject uninstall openproject     # PVC is KEPT (resource-policy), Secret+Cert survive
helm install openproject . -n openproject \
  --set persistence.assets.existingClaim=openproject-assets   # reuse kept PVC
```
The app `Secret` (`openproject-secrets`) and cert-manager `Certificate` are **not** helm-managed, so they survive an uninstall. Only Deployment/Service/Ingress/ConfigMap are recreated.

## Common commands

```bash
# State
kubectl -n openproject get pod,deploy,pvc,ingress,certificate
helm -n openproject list
helm -n openproject history openproject

# Logs / shell
kubectl -n openproject logs deploy/openproject --tail=50
kubectl -n openproject exec -it deploy/openproject -- bash
kubectl -n openproject exec deploy/openproject -- sh -c 'psql "$DATABASE_URL" -c "select version();"'

# CI
gh run list --repo GliaX/openproject --workflow deploy.yml
gh run watch <id> --repo GliaX/openproject

# TLS
kubectl -n openproject get certificate,challenge,order

# Restore assets into the PVC (after a reinstall that lost it)
kubectl -n openproject apply -f - <<EOF        # temp pod on the pinned node
apiVersion: v1
kind: Pod
metadata: {name: assets-migrate, namespace: openproject}
spec:
  nodeSelector: {kubernetes.io/hostname: pool-f971mwbjk-372vs6}
  restartPolicy: Never
  containers:
    - name: a
      image: alpine:3
      command: [sleep, "3600"]
      volumeMounts: [{name: v, mountPath: /mnt/assets}]
  volumes:
    - name: v
      persistentVolumeClaim: {claimName: openproject-assets}
EOF
kubectl -n openproject wait --for=condition=Ready pod/assets-migrate --timeout=120s
kubectl cp ./assets.tar openproject/assets-migrate:/tmp/a.tar
kubectl -n openproject exec assets-migrate -- tar xf /tmp/a.tar -C /mnt/assets
kubectl -n openproject delete pod assets-migrate --wait=false
```

## Secrets & security

- All secrets live in **GitHub Actions repo secrets** → `openproject-secrets` K8s Secret: `DATABASE_URL`, `SECRET_KEY_BASE`, `ENTERPRISE_TOKEN_RB` (the "free enterprise mode" shim, mounted read-only at `/app/app/models/enterprise_token.rb`), `DIGITALOCEAN_ACCESS_TOKEN` (for the deploy workflow's doctl).
- The ghcr image is **public and secret-free** — safe (the enterprise token is mounted via Secret, not baked in). Package visibility is UI-only on GitHub (no API); it was set public once.
- **Past incident (resolved):** a DB dump + assets tarball were accidentally committed to this **public** repo and purged with `git filter-repo` + force-push. The dump was **truncated** (captured only tables A–g) so it exposed **PII** (user/committer emails, GitHub/GitLab identities, document/comment authors) and internal project data, but **no credential secrets** (passwords/oauth/LDAP/storage/webhook/SMTP/2FA tables were past the truncation point). No credential rotation was required; the only cheap defense-in-depth action is rotating the DB user password in `DATABASE_URL`.

## Things to be aware of (environment quirks)

- **DOKS reconciles the CoreDNS ConfigMap** to its managed default — manual edits to the main Corefile get reverted. Don't rely on hand-edited CoreDNS overrides; fix DNS at the source (public record) instead.
- **`doctl` cluster name is `k8s-glia1`** (the kubeconfig *context* is `do-tor1-k8s-glia1`). `doctl kubernetes cluster kubeconfig save k8s-glia1`.
- The cluster's internal resolver caches public DNS with the upstream TTL (3h for glia.org). After a DNS change, allow time before expecting cert-manager self-checks to pass.
- `pip` is blocked by PEP 668 on this workstation; `git-filter-repo` was installed as a standalone script to `~/.local/bin/`.
