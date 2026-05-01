# Multi-Architecture Image Builds

This repository provides custom `Dockerfile`s to build multi-architecture (`linux/amd64`, `linux/arm64`) images for the critical middleware components that lack official ARM support. This enables full integration testing on Apple Silicon Macs.

## Images in this repository

1. **FTS3 Server (`Dockerfile.fts`):** Replaces `rucio/test-fts`. Includes patches for OIDC provider trailing-slash issues.
2. **XRootD SciTokens (`Dockerfile.xrd`):** Adds the SciTokens plugin to the base XRootD image to enable bearer-token TPC on `root://` protocols.

## CI build (GitHub Actions)

Images are built via `.github/workflows/build-images.yml` using a build matrix.
> **Note:** Cross-compilation for `arm64` via QEMU is resource-intensive. FTS3 takes ~60 minutes; XRootD takes ~20 minutes.

## Local build

```bash
# Current platform only (fast)
docker build -t test-fts:local -f deploy/compose/Dockerfile.fts .

# Multi-arch (requires buildx)
docker buildx create --use
docker buildx build --platform linux/amd64,linux/arm64 \
    -t test-fts:local -f deploy/compose/Dockerfile.fts .

# Example for XRootD SciTokens
docker buildx build --platform linux/amd64,linux/arm64 \
    -t test-xrd:local -f deploy/compose/Dockerfile.xrd .

# Example for Rucio Clients with DinD
docker buildx build --platform linux/amd64,linux/arm64 \
    -t rucio-client-docker-kubectl:local -f deploy/compose/Dockerfile.rucio-client-docker-kubectl .
```

## Known issues on macOS (Apple Silicon)

The vfkit driver frequently fails with SSH errors when using [rucio/k8s-tutorial](https://github.com/rucio/k8s-tutorial). When switching to the Docker driver, `fts-server` stalls because `rucio/test-fts` has no `arm64` manifest:

```
Warning  Failed  kubelet  Failed to pull image "rucio/test-fts":
         no matching manifest for linux/arm64/v8 in the manifest list entries
```

**Fix:** use the image built by this repository (`mgajekcern/test-fts`, `test-xrd`) instead.
