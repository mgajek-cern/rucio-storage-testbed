# fts-multiarch-build

## Overview

Builds a multi-architecture (`linux/amd64`, `linux/arm64`) Docker image for the FTS3 server, enabling use of the [rucio/k8s-tutorial](https://github.com/rucio/k8s-tutorial) on Apple Silicon (M1/M2/M3) Macs. The official `rucio/test-fts` image is x86_64 only. This repository provides an arm64-compatible alternative built from source.

The official x86_64 reference image is maintained in the [rucio/containers](https://github.com/rucio/containers/tree/master/test-fts) repository. This repository replicates that setup with a source-based build to support arm64.

## Repository structure
```sh
fts-multiarch-build/
├── .github/workflows/build-fts-multiarch.yml
├── certs/                      # Local certificates — git-ignored almost all files except CA related certificate and private key
│   ├── hostcert.pem            # FTS host certificate (signed by rucio_ca.pem)
│   ├── hostkey.pem             # FTS host private key
│   ├── xrdcert.pem             # XRootD host certificate (signed by rucio_ca.pem)
│   ├── xrdkey.pem              # XRootD host private key
│   ├── rucio_ca.pem            # CA certificate (from k8s-tutorial/secrets/)
│   └── rucio_ca.key.pem        # CA private key (from k8s-tutorial/secrets/)
├── config/
│   ├── fts3config              # FTS3 server configuration
│   ├── fts3restconfig          # REST frontend configuration
│   ├── fts3rest.conf           # Apache/httpd configuration
│   └── fts-activemq.conf       # ActiveMQ messaging configuration
├── scripts/
│   ├── docker-entrypoint.sh
│   ├── test-fts.py             # End-to-end FTS transfer test (run inside FTS container)
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

> **NOTE:** cross-compilation for `linux/arm64` via QEMU on the GitHub Actions ubuntu runner is slow. Expect 45-90 minutes for a full build due to the FTS3 dependency chain (davix, gfal2).

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

The CA certificate must be mounted at the correct OpenSSL hash path. The `rucio_ca.pem` from `k8s-tutorial/secrets/` has hash `5fca1cb1`, so it must be mounted as `5fca1cb1.0`.

### Generating certificates for local testing

If you have access to `k8s-tutorial/secrets/`, copy the existing certificates. They are already signed by the trusted `rucio_ca.pem`:

```bash
cp k8s-tutorial/secrets/hostcert_fts.pem      certs/hostcert.pem
cp k8s-tutorial/secrets/hostcert_fts.key.pem  certs/hostkey.pem
cp k8s-tutorial/secrets/hostcert_xrd1.pem     certs/xrdcert.pem
cp k8s-tutorial/secrets/hostcert_xrd1.key.pem certs/xrdkey.pem
cp k8s-tutorial/secrets/rucio_ca.pem          certs/rucio_ca.pem
chmod 600 certs/hostkey.pem certs/xrdkey.pem
```

If you need to generate new leaf certificates from the Rucio CA (requires the CA private key):

```bash
# FTS host cert
openssl req -nodes -newkey rsa:2048 \
  -keyout certs/hostkey.pem \
  -out    certs/hostcert.csr \
  -subj "/CN=fts"
openssl x509 -req -days 365 \
  -in certs/hostcert.csr \
  -CA certs/rucio_ca.pem -CAkey certs/rucio_ca.key.pem -CAcreateserial \
  -out certs/hostcert.pem
chmod 600 certs/hostkey.pem

# XRootD cert
openssl req -nodes -newkey rsa:2048 \
  -keyout certs/xrdkey.pem \
  -out    certs/xrdcert.csr \
  -subj "/CN=xrd"
openssl x509 -req -days 365 \
  -in certs/xrdcert.csr \
  -CA certs/rucio_ca.pem -CAkey certs/rucio_ca.key.pem -CAcreateserial \
  -out certs/xrdcert.pem
chmod 600 certs/xrdkey.pem

rm -f certs/*.csr certs/*.srl
```

> **Note:** XRootD certificates must use `CN=xrd` (not a hostname). The docker-compose stack configures `XrdSecGSISRVNAMES=*` to bypass hostname verification on both the FTS and XRootD sides, which is required because the cert CN does not match the Docker container hostname.

## Usage

### Run locally with docker-compose

```bash
# 1. Populate certs/ (see above)
# 2. Start the stack
docker compose up -d
```

FTS3 waits for MySQL to be ready before starting. Once running, verify the server:

```bash
# Check server log for successful startup
docker logs fts-multiarch-build-fts-1 | grep "Server started"
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
  --cacert  certs/rucio_ca.pem \
  https://localhost:8446/whoami
# {"user_dn": "/CN=fts", "method": "certificate", "is_root": true, ...}
```

> `--cacert` is required because Apache uses `SSLCACertificatePath` (hash-based lookup).
> curl must trust the same CA to complete the mutual TLS handshake.

### End-to-end transfer test

The `scripts/test-fts.py` script tests the full FTS3 API flow: authentication, proxy delegation, job submission, and transfer polling between xrd1 and xrd2. It uses the `fts3` Python REST client (same approach as Rucio's conveyor daemon) and must be run from inside the FTS container where `M2Crypto` is available for proxy delegation.

A seed file is created automatically when xrd1 starts. To test with additional files, copy them into xrd1 first:

```bash
docker exec fts-multiarch-build-xrd1-1 bash -c \
  'echo "my-data" > /rucio/my-file && chown xrootd:xrootd /rucio/my-file'
```

Then run the test:

```bash
docker exec fts-multiarch-build-fts-1 bash -c 'FTS=https://fts:8446 python3 /scripts/test-fts.py'
```

or run the test, overriding source and destination as needed:

```bash
docker exec fts-multiarch-build-fts-1 bash -c \
  'FTS=https://fts:8446 SRC=root://xrd1//rucio/my-file DST=root://xrd2//rucio/my-file \
   python3 /scripts/test-fts.py'
```

Expected output:
```
=== Step 1: connect and delegate ===
  DN:      /CN=fts
  is_root: True
  method:  certificate
  Delegating proxy...
  Delegation OK
=== Step 2: submit transfer ===
  root://xrd1//rucio/fts-test-file -> root://xrd2//rucio/fts-test-file
  Job ID: f2a91ab6-2769-11f1-b7e3-aa15d8c65909
=== Step 3: poll job status ===
  [  5s] ACTIVE
  [ 10s] FINISHED
Final state: FINISHED
✓ Transfer FINISHED successfully
```

Check xrd2 received the TPC write:

```bash
docker exec fts-multiarch-build-xrd2-1 ls -la /rucio/fts-test-file
```

Expected output:
```
-rw-r--r-- 1 xrootd xrootd 9 Mar 24 10:44 /rucio/fts-test-file
```

The script accepts the following environment variables:

| Variable | Default | Description |
|---|---|---|
| `FTS` | `https://localhost:8446` | FTS3 endpoint |
| `CERT` | `/etc/grid-security/hostcert.pem` | Client certificate |
| `KEY` | `/etc/grid-security/hostkey.pem` | Client private key |
| `SRC` | `root://xrd1//rucio/fts-test-file` | Transfer source URL |
| `DST` | `root://xrd2//rucio/fts-test-file` | Transfer destination URL |

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
  --from-file=tls.cert=certs/rucio_ca.pem \
  -n rucio-tutorial

# Apply manifests through k8s-tutorial/scripts/deploy-rucio.sh
```

## Troubleshooting

### `curl` exit code 56 — authenticated request fails, unauthenticated works

Apache received the connection but the TLS handshake failed. The CA certificate was mounted
but not yet hashed when Apache started. The entrypoint handles this automatically, but if
you see this after a manual `docker run`, run:

```bash
docker exec fts-multiarch-build-fts-1 openssl rehash /etc/grid-security/certificates/
docker exec fts-multiarch-build-fts-1 httpd -k restart
```

### `curl` exit code 35 — SSL connect error, both requests fail

Apache is not listening on port 8446. Check whether it started at all:

```bash
docker exec fts-multiarch-build-fts-1 tail -20 /var/log/httpd/error_log
```

### Transfer fails with `SOURCE [52] Failed to stat file (Invalid exchange)`

GSI hostname verification is failing. The XRootD cert uses `CN=xrd` but the client expects the container hostname. This is handled automatically by `XrdSecGSISRVNAMES=*` set in both the entrypoint and XRootD server config. 

### Transfer fails with `TRANSFER [52]` during TPC (third-party copy)

The XRootD TPC pull, where xrd2's `xrdcp --server` connects to xrd1, fails hostname verification. This is fixed by `setenv XrdSecGSISRVNAMES = *` in the XRootD server config, which the docker-compose entrypoint appends automatically. If you see this after a manual container run, add it to `/etc/xrootd/xrdrucio.cfg` and restart xrootd.

### Transfer stuck in ACTIVE

FTS submitted the job successfully but `fts_url_copy` cannot complete the transfer.
Check the per-transfer log:

```bash
docker exec fts-multiarch-build-fts-1 ls /var/log/fts3/$(date +%Y-%m-%d)/
docker exec fts-multiarch-build-fts-1 cat /var/log/fts3/$(date +%Y-%m-%d)/xrd1__xrd2/<latest-file>
```

And check the XRootD server logs:

```bash
docker logs <xrd-container>
```

### `fts_url_copy` crashes with `Gfal2Exception: /usr/etc/gfal2.d/ is not a valid directory`

The GFAL2 config directory path mismatch. Fixed in the Dockerfile by creating a symlink
`/usr/etc/gfal2.d -> /etc/gfal2.d`. If you see this in an older image, apply manually:

```bash
docker exec fts-multiarch-build-fts-1 bash -c 'mkdir -p /usr/etc && ln -s /etc/gfal2.d /usr/etc/gfal2.d'
```

## Known limitations

- `mod_gridsite` is not available in this source build — X.509 proxy certificate delegation is disabled. Standard certificate authentication via `mod_ssl` (`SSL_CLIENT_CERT`) is fully functional.
- The FTS3 REST frontend (`fts-rest-flask`) is installed from source at `/tmp/fts-rest-flask` rather than via RPM, as the official DMC repository does not provide arm64 packages.
- XRootD GSI hostname verification is disabled via `XrdSecGSISRVNAMES=*` because test certificates use `CN=xrd` rather than the full container hostname. This is acceptable for local development but should not be used in production.

## References

- Official test-fts image (x86_64, RPM-based): https://github.com/rucio/containers/tree/master/test-fts
- Official FTS3 Dockerfile: https://gitlab.cern.ch/fts/fts3/-/blob/3.14.x-release/packaging/docker/Dockerfile
- fts-rest-flask (REST frontend): https://gitlab.cern.ch/fts/fts-rest-flask
- rucio/k8s-tutorial: https://github.com/rucio/k8s-tutorial