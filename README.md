# fts-multiarch-build

## Overview

Builds a multi-architecture (`linux/amd64`, `linux/arm64`) Docker image for the FTS3 server, enabling use of the [rucio/k8s-tutorial](https://github.com/rucio/k8s-tutorial) on Apple Silicon (M1/M2/M3) Macs. The official `rucio/test-fts` image is x86_64 only. This repository provides an arm64-compatible alternative built from source.

The official x86_64 reference image is maintained in the [rucio/containers](https://github.com/rucio/containers/tree/master/fts/test-fts) repository. This repository replicates that setup with a source-based build to support arm64.

## Repository structure
```
fts-multiarch-build/
├── .github/workflows/build-fts-multiarch.yml
├── config/
│   ├── fts3config          # FTS3 server configuration
│   ├── fts3restconfig      # REST frontend configuration
│   ├── fts3rest.conf       # Apache/httpd configuration
│   └── fts-activemq.conf   # ActiveMQ messaging configuration
├── scripts/
│   ├── docker-entrypoint.sh
│   ├── wait-for-it.sh
│   └── logshow
├── Dockerfile
├── docker-compose.yml
└── README.md
```

## Known issues on macOS (Apple Silicon)

### vfkit driver — SSH connection failure

The vfkit driver frequently fails with `no route to host` or `connection refused` SSH errors on macOS when using the [rucio/k8s-tutorial](https://github.com/rucio/k8s-tutorial) repository.
```bash
minikube start --driver=vfkit --rosetta=true --cpus=4 --memory=6000mb
# ...
# ❌ Exiting due to GUEST_PROVISION: error provisioning guest: Failed to start host:
#    provision: Temporary Error: NewSession: dial tcp :22: connect: connection refused
```

**Fix:** use the Docker driver instead — see below.

### Docker driver — `rucio/test-fts` image pull failure

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

## Usage

### Run locally with docker compose (requires MySQL)
```bash
docker compose up
```

FTS3 waits for MySQL to be ready before starting. Once running verify the server:
```bash
# Check server log for successful startup
docker logs <fts-container> | grep "Server started"

# Tail live logs
docker exec <fts-container> tail -f /var/log/fts3/fts3server.log

# Expected output:
# INFO ... Server started
# INFO ... TransfersService interval: 2s
```

### Verify REST endpoint
```bash
# Unauthenticated
curl -sk https://localhost:8446/whoami
# {"user_dn": "anon", "method": "unauthenticated", ...}

# Authenticated with certificate (extract self-signed cert from container first)
docker cp <fts-container>:/etc/grid-security/hostcert.pem /tmp/hostcert.pem
docker cp <fts-container>:/etc/grid-security/hostkey.pem /tmp/hostkey.pem
curl -sk --cert /tmp/hostcert.pem --key /tmp/hostkey.pem https://localhost:8446/whoami
# {"user_dn": "/CN=fts-test", "method": "certificate", "is_root": true, ...}
```

### Standalone container

The FTS3 server requires a MySQL backend. Running the container standalone without a database will cause all FTS services to exit immediately. Use `docker compose` for local testing.

### Smoke test script
```bash
#!/usr/bin/env bash
# scripts/test-endpoints.sh

FTS_HOST="${FTS_HOST:-localhost}"

echo "=== FTS3 endpoint smoke test ==="

echo -n "REST API unauthenticated (8446): "
curl -sf --max-time 10 -k "https://${FTS_HOST}:8446/whoami" && echo "OK" || echo "FAIL"

echo -n "REST API with certificate (8446): "
curl -sf --max-time 10 -k \
  --cert /tmp/hostcert.pem \
  --key /tmp/hostkey.pem \
  "https://${FTS_HOST}:8446/whoami" && echo "OK" || echo "FAIL"

echo "=== Done ==="
```

## Known limitations

- `mod_gridsite` is not available in this source build — X.509 proxy certificate delegation is disabled. Standard certificate authentication via `mod_ssl` (`SSL_CLIENT_CERT`) is fully functional.
- The FTS3 REST frontend (`fts-rest-flask`) is installed from source at `/tmp/fts-rest-flask` rather than via RPM, as the official DMC repository does not provide arm64 packages.
- The duplicate index warning during database initialisation (`idx_link_state_finish_time`) is harmless and suppressed — it occurs because the index is already included in the base schema.

## References

- Official test-fts image (x86_64, RPM-based): https://github.com/rucio/containers/tree/master/fts/test-fts
- Official FTS3 Dockerfile: https://gitlab.cern.ch/fts/fts3/-/blob/3.14.x-release/packaging/docker/Dockerfile
- fts-rest-flask (REST frontend): https://gitlab.cern.ch/fts/fts-rest-flask
- rucio/k8s-tutorial: https://github.com/rucio/k8s-tutorial