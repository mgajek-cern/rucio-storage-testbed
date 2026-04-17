# FTS3 Multi-Architecture Image Build

The `Dockerfile` in this repository builds a multi-architecture (`linux/amd64`, `linux/arm64`) FTS3 server image, enabling use of [rucio/k8s-tutorial](https://github.com/rucio/k8s-tutorial) on Apple Silicon Macs. The official `rucio/test-fts` image is x86_64 only.

The official x86_64 reference image is maintained in [rucio/containers](https://github.com/rucio/containers/tree/master/test-fts). This repository replicates that setup with a source-based build to support arm64.

## CI build (GitHub Actions)

The image is built on manual trigger via `.github/workflows/build-fts-multiarch.yml` using QEMU on an `ubuntu-latest` runner and pushed to Docker Hub.

> Cross-compilation for `linux/arm64` via QEMU is slow — expect 45–90 minutes for a full build.

## Local build

```bash
# Current platform only (fast)
docker build -t test-fts:local .

# Multi-arch (requires buildx)
docker buildx create --use
docker buildx build --platform linux/amd64,linux/arm64 -t test-fts:local .
```

## Known issues on macOS (Apple Silicon)

The vfkit driver frequently fails with SSH errors when using [rucio/k8s-tutorial](https://github.com/rucio/k8s-tutorial). When switching to the Docker driver, `fts-server` stalls because `rucio/test-fts` has no `arm64` manifest:

```
Warning  Failed  kubelet  Failed to pull image "rucio/test-fts":
         no matching manifest for linux/arm64/v8 in the manifest list entries
```

**Fix:** use the image built by this repository (`mgajekcern/test-fts`) instead.
