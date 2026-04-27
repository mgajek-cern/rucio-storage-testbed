# Rucio Storage Testbed — Helm Charts

Kubernetes translation of the `rucio-storage-testbed` docker-compose stack,
following the idioms of [rucio/helm-charts](https://github.com/rucio/helm-charts)
and [rucio/k8s-tutorial](https://github.com/rucio/k8s-tutorial).

## Layout

```
helm-charts/
├── rucio-storage-testbed/        # Umbrella (meta) chart — deploy this
│   ├── Chart.yaml                # Declares deps on all subcharts below
│   ├── values.yaml               # Single source of truth (toggle services, OIDC, etc.)
│   ├── files/                    # Symlinks to repo root (fixed for Helm context)
│   │   ├── certs/    → ../../../certs
│   │   ├── configs/  → ../../../shared/config
│   │   ├── patches/  → ../../../shared/patches
│   │   └── scripts/  → ../../../shared/scripts
│   └── templates/
│       ├── certs-secret.yaml         # All host/CA certs as one Secret
│       ├── configs-cm.yaml           # Shared config files as ConfigMap(s)
│       ├── patches-secret.yaml       # Python patches (rucio fts3.py, constants.py, fts middleware/oidc)
│       ├── rucio-cfg-secrets.yaml    # Pass-through Secrets for rucio-server's secretMounts
│       └── scripts-cm.yaml           # Bootstrap & entrypoint scripts
│
├── fts/                          # Custom image (Dockerfile.fts) — GSI + OIDC FTS server
├── xrootd/                       # rucio/test-xrootd (GSI)
├── xrootd-scitokens/             # Custom image (Dockerfile.xrd-scitokens) — XRootD with scitokens
├── storm-webdav/                 # ghcr.io/italiangrid/storm-webdav
├── webdav/                       # rucio/test-webdav (Apache + WebDAV)
├── minio/                        # minio/minio + mc init Job
├── keycloak/                     # quay.io/keycloak/keycloak
└── rucio-client/                 # Custom image (Dockerfile.rucio-client-dind)
```

`ruciodb` / `ruciodb-oidc` reuse `bitnami/postgresql`, and the two Rucio
server deployments reuse the upstream `rucio/rucio-server` chart — both are
declared as dependencies of the umbrella chart.

## Repairing Symlinks

```bash
# Navigate to the umbrella chart's files directory
cd rucio-storage-testbed/files

# Recreate corrected links (4 levels up to reach repo root)
rm -f certs configs patches scripts
ln -s ../../../../certs certs
ln -s ../../../../shared/config configs
ln -s ../../../../shared/patches patches
ln -s ../../../../shared/scripts scripts
```

## Quickstart

```sh
# 1. Generate certs (once) from repo root
./scripts/generate-certs.sh

# 2. Create the namespace and install
kubectl create namespace rucio-testbed
helm dependency update helm-charts/rucio-storage-testbed
helm install testbed helm-charts/rucio-storage-testbed --namespace rucio-testbed
```

You should end up with something like:

```bash
$ kubectl get pods -n rucio-testbed
NAME                            READY   STATUS    RESTARTS   AGE
fts-554f49847f-xs7w8            1/1     Running   0          6s
fts-oidc-599db94fc6-mkzvd       1/1     Running   0          6s
ftsdb-0                         1/1     Running   0          6s
ftsdb-oidc-0                    1/1     Running   0          6s
keycloak-859468646d-jxrj7       1/1     Running   0          6s
minio1-0                        1/1     Running   0          6s
minio2-0                        1/1     Running   0          6s
rucio-66bccfb774-pnk89          2/2     Running   0          6s
rucio-client-77bd45466d-k4d7g   1/1     Running   0          6s
rucio-oidc-6f4c6b6784-5n8h7     2/2     Running   0          6s
ruciodb-0                       1/1     Running   0          6s
ruciodb-oidc-0                  1/1     Running   0          6s
storm1-0                        1/1     Running   0          6s
storm2-0                        1/1     Running   0          6s
webdav1-7d46f9455b-62m9h        1/1     Running   0          6s
webdav2-cc677bd59-7vtj8         1/1     Running   0          6s
xrd1-76ff88f7d-nrn49            1/1     Running   0          6s
xrd2-6dd8869444-dm7qb           1/1     Running   0          6s
xrd3-5c8995cf57-zhxxz           1/1     Running   0          6s
xrd4-f85499bf8-t8zqz            1/1     Running   0          6s
```

Tear down:

```sh
helm uninstall testbed -n rucio-testbed
kubectl -n rucio-testbed delete pvc --all   # PVCs aren't removed by `helm uninstall`
```

## Design notes

* **Configs, patches and scripts** — everything under `shared/config/`,
  `shared/patches/`, and `shared/scripts/` in the repo — are exposed to pods
  through ConfigMaps or Secrets managed by the umbrella
  chart. The umbrella's `files/` directory contains symlinks into the repo's
  shared/ tree, so the chart and the compose stack consume identical sources
  with no duplication.
* **Certificates** live in a single Secret (`testbed-certs`), populated from
  `files/certs/` (a symlink to `./certs/` at the repo root). Each pod mounts
  only the keys it needs via `subPath`. Regenerate the certs with
  `./scripts/generate-certs.sh` and re-run `helm upgrade`.
* **Service discovery** — every subchart's Service is named to match the
  compose `hostname:` value, so existing config files referencing
  `https://keycloak:8443`, `https://fts:8446`, etc. work without modification.
* **Reuse over reinvention** — `rucio-server` and `postgresql` come from
  upstream charts as dependencies; only services without a usable upstream
  chart (FTS, StoRM-WebDAV, the scitokens XRootD, etc.) ship as new local
  charts.
* **OIDC subchart alias** — the second `rucio-server` dependency is aliased
  as `rucio-oidc` (hyphen, not camelCase) because the upstream chart
  templates the alias into a container `name:` field, and Kubernetes
  enforces RFC 1123 there. Values for it sit under the `"rucio-oidc":`
  key in `values.yaml` and are accessed in templates with
  `(index .Values "rucio-oidc")`.
