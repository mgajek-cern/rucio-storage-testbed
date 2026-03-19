# fts-multiarch-build

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
#   Warning  Failed     3m17s (x5 over 6m12s)  kubelet            Failed to pull image "rucio/test-fts": no matching manifest for linux/arm64/v8 in the manifest list entries
#   Warning  Failed     3m17s (x5 over 6m12s)  kubelet            Error: ErrImagePull
#   Warning  Failed     65s (x20 over 6m12s)   kubelet            Error: ImagePullBackOff
#   Normal   BackOff    50s (x21 over 6m12s)   kubelet            Back-off pulling image "rucio/test-fts"
```

**Fix:** enable "Use Rosetta for x86/amd64 emulation" in Docker Desktop settings, or run the tutorial on a native x86_64 Linux host.

## TODO

- build (Ref: https://gitlab.cern.ch/fts/fts3/-/blob/3.14.x-release/packaging/docker/Dockerfile?ref_type=heads) for arm64 arch
