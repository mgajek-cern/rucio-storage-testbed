# Known Issues

This document tracks known bugs, open investigations, and workarounds in the
rucio-storage-testbed. The goal is to prevent re-investigation of issues that
have already been examined.

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
