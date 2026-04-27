# Known Issues

This document tracks known bugs, open investigations, and workarounds in the
rucio-storage-testbed. The goal is to prevent re-investigation of issues that
have already been examined.

## XRootD GSI transfers fail on Kubernetes runtime (k8s)

**Status:** Open. Workaround: skip the test on k8s.
**Affects:** `make test-xrootd-gsi`, `make test-rucio` (XRD1→XRD2 leg only).
**Doesn't affect:** Compose runtime (passes), OIDC paths on either runtime
(StoRM OIDC and XRootD OIDC both pass).

### Symptom

`SOURCE [52] Failed to stat file (Invalid exchange)` from FTS when transferring
between two `rucio/test-xrootd` instances. xrd1 logs show
`XrootdXeq: fts3.NNN:NN@... disc 0:00:00` — the connection authenticates and
then disconnects in zero seconds, with no further detail.

### What we ruled out

- Cert mounts and modes are correct on both FTS and xrd1.
- Both pods trust the rucio CA at the canonical hash path.
- xrd1's host cert is valid, signed by the CA, modes 0400 on the key.
- The grid-mapfile in the pod contains `/CN=fts xrootd` and `/CN=fts/CN=proxy
  xrootd`, byte-identical to the source.
- The xrootd process is running and listening on 1094.
- TCP from the FTS pod to xrd1:1094 succeeds.
- xrootd is loading the right config, including `sec.protocol gsi` directives.
- The image's entrypoint successfully copies certs into `/etc/grid-security/xrd/`
  with correct ownership and modes (verified post-boot).
- Enabling `secgsi -d:3` in the xrootd config produces full debug output during
  init, but no per-connection debug for the FTS attempts that fail.

### What we observed

- Enabling debug requires mounting a custom `xrdrucio.cfg` over the image's
  baked-in default. But the image's `docker-entrypoint.sh` appends to that
  file at startup (`echo "xrd.port $XRDPORT" >> ...`), which fails on a
  read-only subPath mount. This breaks observability of the GSI handshake.
- The compose runtime uses bind mounts (writable), so the same image works.
- Auth completes (xrootd logs the user as `fts3.NNN`) but the connection
  is dropped immediately afterward, before the client can issue a `stat`.

### Hypotheses (untested)

1. Some post-auth step in xrootd (e.g., a `seteuid` to the mapped user, or
   a TLS-channel completion handshake) fails silently due to a difference
   between Docker bind-mount semantics and Kubernetes Secret/ConfigMap
   subPath semantics that we have not yet identified.
2. The image's default config has hidden assumptions about file paths or
   permissions that our k8s mount layout doesn't satisfy.
3. A subtle interaction between the entrypoint's append-to-config behavior
   and the resulting xrootd config state.

### Path forward

Resolution likely requires either:
- Building a custom xrootd image with debug pre-baked in (so we don't need
  to mount over the config), and reproducing the failure to capture the
  per-connection secgsi debug log.
- Switching to a more recent rucio/test-xrootd build, if upstream has
  addressed similar issues.
- Or accepting that the GSI test is compose-only and relying on OIDC for
  k8s storage transfers (the strategic direction anyway).

### Workaround in CI

`test-xrootd-gsi` is skipped on the k8s CI matrix. It still runs on the
compose CI matrix, so regressions in the GSI auth path itself would be
caught.

## S3 / MinIO test: HTTP 400 on VO grant (k8s)

**Status:** Open. Likely a quick fix but unverified.

`make test-s3` fails on k8s with:

```
register S3:minio1: HTTP 201
grant VO access to S3:minio1: HTTP 400
```

The credential registers fine; the VO grant fails. Probably the VO
identifier the test uses doesn't match what the rucio-oidc instance is
configured with on k8s (the OIDC FTS instance shows
`vos: ["637380c6b100c14e"]`, which is a hashed identifier, not "def").

Investigate by capturing the request body and rucio-oidc server logs
during the call.

## WebDAV transfer fails on k8s

**Status:** Same root cause as XRootD GSI (likely).

`make test-webdav` produces:

```
SOURCE [52] Failed to stat file (Invalid exchange)
source_se: root://xrd1
```

The transfer is `xrd1 → webdav1`, and the source-side failure is GSI
against xrd1 — the same path that fails in `test-xrootd-gsi`. Once GSI
is resolved, this likely resolves with it.

## rucio-client pod has cluster exec permissions on k8s

The `rucio-client` pod ships with `kubectl` and a ServiceAccount that
grants `get`/`list`/`create` on `pods/exec`, `pods`, and `deployments`
within the testbed namespace. This lets `test-rucio-transfers.py`
orchestrate seed/setup operations against storage and FTS pods the
same way the compose version uses the docker socket.

This is appropriate for a development testbed but should be reviewed
before adopting the chart in shared or production-adjacent clusters.
The ServiceAccount is namespace-scoped (Role/RoleBinding, not Cluster*),
so blast radius is limited to the testbed namespace.
