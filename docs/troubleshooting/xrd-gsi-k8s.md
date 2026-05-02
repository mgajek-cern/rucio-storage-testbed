# XRootD GSI Transfers on Kubernetes — Troubleshooting Guide

## Root Causes (resolved)

Five independent issues combined to break GSI TPC on k8s while compose worked fine.

### 1. CA trust bundle not rebuilt (`update-ca-trust` missing)

The CA cert was mounted at `/etc/pki/ca-trust/source/anchors/rucio-ca.crt` but
`update-ca-trust extract` was never called in the container entrypoint. The
consolidated `ca-bundle.crt` used by OpenSSL (and therefore by xrdcp workers
spawned by `fts_server`) remained stale. The `cat >>` workaround only patched
the live file and was lost on daemon fork.

**Fix:** call `update-ca-trust extract` as the first command in the FTS
entrypoint, before launching any service.

### 2. CA hash files and signing policies not mounted

XRootD's GSI implementation (`libXrdSecgsi`) requires both `<hash>.0` and
`<hash>.signing_policy` in the `certdir`. The old mounts provided only
`5fca1cb1.0` (renamed from `rucio_ca.pem`), missing the signing policy and the
old-style hash (`b96dc756.*`). Without these, `GetSrvCertEnt` fails to build
the CA list and XRootD exits with:

```
unable to generate ca cert hash list!
Config Failed to load gsi authentication protocol!
```

In Docker Compose the entire `certs/` directory is bind-mounted, so all files
are present automatically. In Kubernetes each file must be explicitly listed.

**Fix:** generate all four trust-anchor files in `generate-certs.sh` and mount
`5fca1cb1.0`, `5fca1cb1.signing_policy`, `b96dc756.0`, `b96dc756.signing_policy`
into every pod that runs XRootD or acts as a GSI client (FTS, xrd1–xrd4).

### 3. CA files mounted with mode 0600 (unreadable by `fts3` user)

Kubernetes Secret volumes default to `0600`. The `fts_server` daemon runs as
`fts3`, not root, so the CA hash files in `/etc/grid-security/certificates/`
were unreadable by the xrdcp worker processes, causing silent TLS failures:

```
tlsv1 alert unknown ca  (SSL alert number 48)
```

**Fix:** specify `mode: 0644` per item in the Secret volume `items` list for
all non-private-key files (CA certs, signing policies).

### 4. CRL check level set to `-crl:3` (requires CRL files that don't exist)

The xrootd config had `-crl:3` (require non-expired CRL). The testbed CA has
no CRL distribution point and no `.r0` files are generated. With `-crl:3`,
`LoadCRL` returns an error and the CA is marked invalid even when all cert
files are present and readable.

**Fix:** use `-crl:0` in `xrdrucio-gsi.cfg` for the testbed.

### 5. `xrdrucio.cfg` mounted as read-only subPath — breaks entrypoint append

The xrootd `docker-entrypoint.sh` appends `xrd.port $XRDPORT` to the config
file at startup. A Kubernetes `subPath` mount is always read-only from the
container's perspective regardless of the `readOnly:` flag, so this `echo >>`
fails silently and the port directive is never written.

**Fix:** bake `xrd.port 1094` into the static config file (`xrdrucio-gsi.cfg`)
so the entrypoint append is not needed, or remove the append from the
entrypoint entirely.

---

## Symptom → Root Cause Map

| Symptom | Cause |
|---|---|
| Job stuck in `SUBMITTED` | `update-ca-trust` not run; xrdcp can't verify xrd server cert |
| `unable to generate ca cert hash list` / xrootd exits | Missing `.signing_policy` or second hash file |
| `tlsv1 alert unknown ca` from FTS pod IP | CA files mode `0600`, unreadable by `fts3` user |
| `Job stuck in ACTIVE`, `Throughput: 0` | Any of the above affecting xrdcp workers post-fork |
| `SOURCE [52] Failed to stat file (Invalid exchange)` | Auth completes but subsequent step fails (often file permissions or proxy delegation issue) |
| xrootd exits immediately in k8s | `-crl:3` with no CRL files present |

---

## Checklist for New Environments

```bash
# 1. Verify CA files are present and readable in FTS pod
kubectl -n rucio-testbed exec deploy/fts -- \
  ls -la /etc/grid-security/certificates/
# Expect: 5fca1cb1.0, 5fca1cb1.signing_policy, b96dc756.0, b96dc756.signing_policy
# Expect: mode 644, readable by all

# 2. Verify CA is in the consolidated bundle
kubectl -n rucio-testbed exec deploy/fts -- \
  grep -c 'Rucio' /etc/pki/tls/certs/ca-bundle.crt
# Expect: 1

# 3. Verify proxy exists and has correct mode
kubectl -n rucio-testbed exec deploy/fts -- \
  ls -la /tmp/x509up_u0
# Expect: -rw------- (0600)

# 4. Verify manual xrootd access works from FTS pod
kubectl -n rucio-testbed exec deploy/fts -- \
  xrdfs xrd1 ls /rucio/
# Expect: /rucio/fts-test-file

# 5. Run the test
RUNTIME=k8s make test-xrootd-gsi
```
