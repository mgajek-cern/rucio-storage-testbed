# Rucio Storage Testbed — Helm Charts

Kubernetes translation of the `rucio-storage-testbed` docker-compose stack,
following the idioms of [rucio/helm-charts](https://github.com/rucio/helm-charts)
and [rucio/k8s-tutorial](https://github.com/rucio/k8s-tutorial).

## Layout

```
charts/
├── rucio-storage-testbed/   # Umbrella (meta) chart — deploy this
│   ├── Chart.yaml           # Declares deps on all subcharts below
│   ├── values.yaml          # Single source of truth (toggle VOs, OIDC, etc.)
│   └── templates/
│       ├── certs-secret.yaml   # All host/CA certs as one Secret
│       ├── configs-cm.yaml     # All shared config files as ConfigMaps
│       ├── patches-cm.yaml     # Python patches (rucio fts3.py, constants.py, fts middleware/oidc)
│       └── scripts-cm.yaml     # Bootstrap & entrypoint scripts
│
├── fts/                     # Custom image (Dockerfile.fts) — GSI + OIDC FTS server
├── xrootd/                  # rucio/test-xrootd (GSI)
├── xrootd-scitokens/        # Custom image (Dockerfile.xrd-scitokens) — XRootD with scitokens
├── storm-webdav/            # ghcr.io/italiangrid/storm-webdav
├── webdav/                  # rucio/test-webdav (Apache+WebDAV)
├── minio/                   # minio/minio + mc init Job
├── keycloak/                # quay.io/keycloak/keycloak
└── rucio-client/            # Custom image (Dockerfile.rucio-client-dind)
```

`ruciodb` / `ruciodb-oidc` reuse `bitnami/postgresql`, and the Rucio server
deployments reuse the upstream `rucio/rucio-server` chart — both declared as
dependencies of the umbrella chart.

## Quickstart

```sh
# 1. Generate certs (once) using the testbed's existing helper:
#    ./scripts/generate-certs.sh   (from the rucio-storage-testbed repo)
# 2. Create the namespace and install:
kubectl create namespace rucio-testbed
helm dependency update charts/rucio-storage-testbed
helm install testbed charts/rucio-storage-testbed \
  --namespace rucio-testbed \
  --set-file certs.hostcert=./certs/hostcert.pem \
  --set-file certs.hostkey=./certs/hostkey.pem \
  ... (see values.yaml for the full list)
```

In practice, create a single `values-certs.yaml` with `--set-file` entries and
pass it with `-f`.

## Design notes

* **Configs, patches and scripts** (everything under `shared/config/`,
  `shared/patches/`, `shared/scripts/` in the compose repo) are mounted from
  ConfigMaps managed by the umbrella chart — the same way the compose file
  bind-mounts them read-only.
* **Certificates** live in a single Secret (`testbed-certs`) and each pod mounts
  only the keys it needs via `subPath`.
* **Service discovery**: every subchart's Service is named to match the compose
  `hostname:` value, so the existing config files that reference
  `https://keycloak:8443`, `https://fts:8446`, etc. need no changes.
* **Reuse over reinvention**: `rucio-server` and `postgresql` come from upstream
  charts as dependencies; only services without a usable upstream chart
  (FTS, StoRM, the scitokens XRootD, etc.) ship as new charts.
