# fts-multiarch-build

## Overview

Builds a multi-architecture (`linux/amd64`, `linux/arm64`) Docker image for the FTS3 server, enabling use of the [rucio/k8s-tutorial](https://github.com/rucio/k8s-tutorial) on Apple Silicon (M1/M2/M3) Macs. The official `rucio/test-fts` image is x86_64 only. This repository provides an arm64-compatible alternative built from source.

The official x86_64 reference image is maintained in the [rucio/containers](https://github.com/rucio/containers/tree/master/fts/test-fts) repository. This repository replicates that setup with a source-based build to support arm64.

## Repository structure
```
fts-multiarch-build/
├── .github/workflows/build-fts-multiarch.yml
├── certs/                      # Local certificates — git-ignored, you must create this
│   ├── hostcert.pem
│   ├── hostkey.pem
│   └── ca.pem
├── config/
│   ├── fts3config              # FTS3 server configuration
│   ├── fts3restconfig          # REST frontend configuration
│   ├── fts3rest.conf           # Apache/httpd configuration
│   └── fts-activemq.conf       # ActiveMQ messaging configuration
├── scripts/
│   ├── docker-entrypoint.sh
│   ├── wait-for-it.sh
│   └── logshow
├── Dockerfile
├── docker-compose.yml
└── README.md
```

## Known issues on macOS (Apple Silicon)

The vfkit driver frequently fails with `no route to host` or `connection refused` SSH errors on macOS when using the [rucio/k8s-tutorial](https://github.com/rucio/k8s-tutorial) repository.
```bash
minikube start --driver=vfkit --rosetta=true --cpus=4 --memory=6000mb
# ...
# ❌ Exiting due to GUEST_PROVISION: error provisioning guest: Failed to start host:
#    provision: Temporary Error: NewSession: dial tcp :22: connect: connection refused
```

When switching to the Docker driver, the `fts-server` deployment stalls because `rucio/test-fts` has no `arm64` manifest:
```bash
kubectl describe pod <fts-server pod> -n rucio-tutorial
#   Warning  Failed     3m17s (x5 over 6m12s)  kubelet  Failed to pull image "rucio/test-fts": no matching manifest for linux/arm64/v8 in the manifest list entries
#   Warning  Failed     3m17s (x5 over 6m12s)  kubelet  Error: ErrImagePull
#   Warning  Failed     65s (x20 over 6m12s)   kubelet  Error: ImagePullBackOff
#   Normal   BackOff    50s (x21 over 6m12s)   kubelet  Back-off pulling image "rucio/test-fts"
```

**Fix:** use the image built by this repository instead (see usage below).

## Build

### CI (GitHub Actions)

The image is built via manual trigger via `.github/workflows/build-fts-multiarch.yml` using QEMU emulation on an `ubuntu-latest` (x86_64) runner and pushed to Docker Hub.

![Image in Dockerhub](./images/docker-image-in-docker-hub.png.png)

> **NOTE:** cross-compilation for `linux/arm64` via QEMU on the GitHub Actions ubuntu runner is slow. Expect 45-90 minutes for a full build due to the FTS3 dependency chain (davix, gfal2, voms, gridsite, dirq, soci).

### Local build
```bash
# Build for your current platform only (fast)
docker build -t test-fts:local .

# Build multi-arch (requires buildx)
docker buildx create --use
docker buildx build --platform linux/amd64,linux/arm64 -t test-fts:local .
```

## Certificates

Certificates are **not** baked into the image. They must be provided at runtime via volume mounts (docker-compose) or Kubernetes Secrets.

The entrypoint runs `openssl rehash /etc/grid-security/certificates/` before Apache starts, so plain `.pem` CA files are automatically hashed at container startup — no manual pre-hashing required.

### Generating certificates for local testing

```bash
mkdir -p certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/hostkey.pem \
  -out    certs/hostcert.pem \
  -subj "/CN=fts-test"
chmod 600 certs/hostkey.pem
# Use the host cert as the local CA as well
cp certs/hostcert.pem certs/ca.pem
```

## Usage

### Run locally with docker-compose

```bash
# 1. Generate certificates (see above) or place real ones in ./certs/
# 2. Start the stack
docker-compose up
```

FTS3 waits for MySQL to be ready before starting. Once running, verify the server:

```bash
# Check server log for successful startup
docker logs <fts-container> | grep "Server started"

# Tail live logs
docker exec <fts-container> tail -f /var/log/fts3/fts3server.log

# Expected output:
# INFO ... Server started
# INFO ... TransfersService
```

### Verify REST endpoint

```bash
# Unauthenticated
curl -sk https://localhost:8446/whoami
# {"user_dn": "anon", "method": "unauthenticated", ...}

# Authenticated with the mounted certificate
curl -sk \
  --cert    certs/hostcert.pem \
  --key     certs/hostkey.pem \
  --cacert  certs/ca.pem \
  https://localhost:8446/whoami
# {"user_dn": "/CN=fts-test", "method": "certificate", "is_root": true, ...}
```

> `--cacert` is required because Apache uses `SSLCACertificatePath` (hash-based lookup).
> curl must trust the same CA to complete the mutual TLS handshake.

### Standalone container

The FTS3 server requires a MySQL backend. Running the container standalone without a database will cause all FTS services to exit immediately. Use `docker-compose` for local testing.

### Smoke test script

```bash
#!/usr/bin/env bash
# scripts/test-endpoints.sh

FTS_HOST="${FTS_HOST:-localhost}"
CERT_DIR="${CERT_DIR:-./certs}"

echo "=== FTS3 endpoint smoke test ==="

echo -n "REST API unauthenticated (8446): "
curl -sf --max-time 10 -k "https://${FTS_HOST}:8446/whoami" && echo "OK" || echo "FAIL"

echo -n "REST API with certificate (8446): "
curl -sf --max-time 10 -k \
  --cert   "${CERT_DIR}/hostcert.pem" \
  --key    "${CERT_DIR}/hostkey.pem" \
  --cacert "${CERT_DIR}/ca.pem" \
  "https://${FTS_HOST}:8446/whoami" && echo "OK" || echo "FAIL"

echo "=== Done ==="
```

### Kubernetes

Certificates are stored as Kubernetes Secrets and volume-mounted into the pod. See `k8s-tutorial/manifests/fts.yaml` for the full manifest.

```bash
# Create the host certificate Secret
kubectl create secret tls hostcert-fts \
  --cert=certs/hostcert.pem \
  --key=certs/hostkey.pem \
  -n rucio-tutorial

# Create the CA certificate Secret
kubectl create secret generic ca-cert \
  --from-file=tls.cert=certs/ca.pem \
  -n rucio-tutorial

# Apply manifests trough k8s-tutorial/scripts/deploy-rucio.sh
```

## Troubleshooting

### `curl` exit code 56 — authenticated request fails, unauthenticated works

Apache received the connection but the TLS handshake failed. This means the CA certificate
was mounted but not yet hashed when Apache started. The entrypoint handles this automatically,
but if you see this after a manual `docker run` (bypassing the entrypoint), run:

```bash
docker exec <fts-container> openssl rehash /etc/grid-security/certificates/
docker exec <fts-container> httpd -k restart
```

### `curl` exit code 35 — SSL connect error, both requests fail

Apache is not listening on port 8446. Check whether it started at all:

```bash
docker exec <fts-container> ps aux | grep httpd
docker exec <fts-container> tail -20 /var/log/httpd/error_log
```

## Known limitations

- `mod_gridsite` is not available in this source build — X.509 proxy certificate delegation is disabled. Standard certificate authentication via `mod_ssl` (`SSL_CLIENT_CERT`) is fully functional.
- The FTS3 REST frontend (`fts-rest-flask`) is installed from source at `/tmp/fts-rest-flask` rather than via RPM, as the official DMC repository does not provide arm64 packages.

## References

- Official test-fts image (x86_64, RPM-based): https://github.com/rucio/containers/tree/master/test-fts
- Official FTS3 Dockerfile: https://gitlab.cern.ch/fts/fts3/-/blob/3.14.x-release/packaging/docker/Dockerfile
- fts-rest-flask (REST frontend): https://gitlab.cern.ch/fts/fts-rest-flask
- rucio/k8s-tutorial: https://github.com/rucio/k8s-tutorial