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
│   ├── webdav1cert.pem         # WebDAV1 host certificate (signed by rucio_ca.pem, CN=webdav1)
│   ├── webdav1key.pem          # WebDAV1 host private key
│   ├── webdav2cert.pem         # WebDAV2 host certificate (signed by rucio_ca.pem, CN=webdav2)
│   ├── webdav2key.pem          # WebDAV2 host private key
│   ├── rucio_ca.pem            # CA certificate (from k8s-tutorial/secrets/)
│   └── rucio_ca.key.pem        # CA private key (from k8s-tutorial/secrets/)
├── config/
│   ├── fts3config              # FTS3 server configuration
│   ├── fts3restconfig          # REST frontend configuration
│   ├── fts3rest.conf           # Apache/httpd configuration
│   ├── fts-activemq.conf       # ActiveMQ messaging configuration
│   └── gfal2_http_plugin.conf  # gfal2 HTTP plugin config (S3/MinIO credentials, INSECURE=true for WebDAV)
├── scripts/
│   ├── docker-entrypoint.sh
│   ├── test-fts-with-xrootd.py # End-to-end XRootD TPC transfer test (run inside FTS container)
│   ├── test-fts-with-s3.sh     # End-to-end S3/MinIO transfer test (run from repo root)
│   ├── test-webdav.sh          # End-to-end WebDAV transfer test (run from repo root)
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

If you need to generate new leaf certificates from the Rucio CA (requires the CA private key):

```bash
# FTS host cert — must include Key Usage for XRootD GSI TPC proxy delegation
cat > /tmp/fts-ext.cnf << 'EOF'
[ v3_req ]
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF

openssl req -nodes -newkey rsa:2048 \
  -keyout certs/hostkey.pem \
  -out    certs/hostcert.csr \
  -subj "/CN=fts"
openssl x509 -req -days 365 \
  -in certs/hostcert.csr \
  -CA certs/rucio_ca.pem -CAkey certs/rucio_ca.key.pem -CAcreateserial \
  -extfile /tmp/fts-ext.cnf -extensions v3_req \
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

# WebDAV certs — CN must match each container hostname
openssl req -nodes -newkey rsa:2048 \
  -keyout certs/webdav1key.pem \
  -out    certs/webdav1cert.csr \
  -subj "/CN=webdav1"
openssl x509 -req -days 365 \
  -in certs/webdav1cert.csr \
  -CA certs/rucio_ca.pem -CAkey certs/rucio_ca.key.pem -CAcreateserial \
  -out certs/webdav1cert.pem
chmod 600 certs/webdav1key.pem

openssl req -nodes -newkey rsa:2048 \
  -keyout certs/webdav2key.pem \
  -out    certs/webdav2cert.csr \
  -subj "/CN=webdav2"
openssl x509 -req -days 365 \
  -in certs/webdav2cert.csr \
  -CA certs/rucio_ca.pem -CAkey certs/rucio_ca.key.pem -CAcreateserial \
  -out certs/webdav2cert.pem
chmod 600 certs/webdav2key.pem

rm -f certs/*.csr certs/*.srl /tmp/fts-ext.cnf
```

> **NOTE:** The FTS host certificate **must** include `Key Usage = digitalSignature, keyEncipherment`. Without this extension, XRootD's GSI implementation cannot create a proxy certificate for TPC authentication, causing transfers to fail with `no delegated credentials for tpc`.

> **NOTE:** XRootD certificates use `CN=xrd` (not a hostname). The docker-compose stack configures `XrdSecGSISRVNAMES=*` to bypass hostname verification, which is required because the cert CN does not match the Docker container hostname.

> **NOTE:** Each WebDAV certificate must use a CN matching its container hostname (`CN=webdav1` and `CN=webdav2`). Connections from inside the Docker network use these hostnames for TLS SNI validation.

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

### End-to-end transfer test with XRootD

The `scripts/test-fts-with-xrootd.py` script tests the full FTS3 API flow: authentication, proxy delegation, job submission, and transfer polling between xrd1 and xrd2. It uses the `fts3` Python REST client (same approach as Rucio's conveyor daemon) and must be run from inside the FTS container where `M2Crypto` is available for proxy delegation.

A seed file is created automatically when xrd1 starts. To test with additional files, copy them into xrd1 first:

```bash
docker exec fts-multiarch-build-xrd1-1 bash -c \
  'echo "my-data" > /rucio/my-file && chown xrootd:xrootd /rucio/my-file'
```

Then run the test:

```bash
docker exec fts-multiarch-build-fts-1 bash -c 'FTS=https://fts:8446 python3 /scripts/test-fts-with-xrootd.py'
```

or override source and destination as needed:

```bash
docker exec fts-multiarch-build-fts-1 bash -c \
  'FTS=https://fts:8446 SRC=root://xrd1//rucio/my-file DST=root://xrd2//rucio/my-file \
   python3 /scripts/test-fts-with-xrootd.py'
```

Expected output:
```
=== Step 1: connect and delegate ===
  DN:      /CN=fts
  is_root: True
  method:  certificate
  Delegation OK
=== Step 2: submit transfer ===
  root://xrd1//rucio/fts-test-file -> root://xrd2//rucio/fts-test-file
  Job ID: d33ae870-2788-11f1-8365-e62107ed9546
=== Step 3: poll job status ===
  [  5s] FINISHED
Final state: FINISHED
✓ Transfer FINISHED successfully
```

Check xrd2 received the file:

```bash
docker exec fts-multiarch-build-xrd2-1 ls -la /rucio/fts-test-file
```

The script accepts the following environment variables:

| Variable | Default | Description |
|---|---|---|
| `FTS` | `https://localhost:8446` | FTS3 endpoint |
| `CERT` | `/etc/grid-security/hostcert.pem` | Client certificate |
| `KEY` | `/etc/grid-security/hostkey.pem` | Client private key |
| `SRC` | `root://xrd1//rucio/fts-test-file` | Transfer source URL |
| `DST` | `root://xrd2//rucio/fts-test-file` | Transfer destination URL |

### End-to-end transfer test with S3 (MinIO)

The `scripts/test-fts-with-s3.sh` script tests FTS transfers to and from the MinIO S3-compatible storage. It runs from the repo root (no exec into container needed).

#### How S3 support works on arm64

S3 support instead comes from davix, which is built from source and has full AWS SigV4 signing support. Two things are required in `config/gfal2_http_plugin.conf`:

- `ALTERNATE=true` — enables path-style S3 URLs (`host:port/bucket/key`) required by MinIO. Without this, davix uses virtual-hosted style (`bucket.host/key`) which MinIO rejects.
- `ACCESS_KEY` / `SECRET_KEY` — credentials mounted directly into the FTS container, since `fts_url_copy` does not inject cloud storage DB credentials into the gfal2 context at runtime.

The FTS cloud storage DB registration (two API calls in the script) is still performed for consistency with how production FTS setups work, but the actual SigV4 signing uses the config file credentials.

#### Running the test

```bash
./scripts/test-fts-with-s3.sh
```

Expected output:
```
=== Registering S3 credentials ===
  VO: 637380c6b100c14e
  register storage: HTTP 201
  grant VO access with credentials: HTTP 201
=== Delegating proxy ===
  delegate: HTTP 201

=== S3: xrd1 → MinIO ===
  Job: ea5cba1a-2788-11f1-9185-e62107ed9546
  [1] FINISHED
✓ FINISHED

=== S3: MinIO → xrd2 ===
  Job: ed6bf072-2788-11f1-9406-e62107ed9546
  [1] FINISHED
✓ FINISHED

=== S3: MinIO → MinIO (streamed, no native TPC) ===
  Job: f07b71c0-2788-11f1-8365-e62107ed9546
  [1] FINISHED
✓ FINISHED

--- MinIO1/MinIO2 buckets contents ---
[2026-03-24 13:50:19 UTC]     9B STANDARD fts-test-file
[2026-03-24 13:54:14 UTC]     9B STANDARD fts-test-file-copy
[2026-03-24 13:54:04 UTC]     9B STANDARD fts-test-file-from-xrd1
```

MinIO1→MinIO2 within the same endpoint uses a streamed transfer (data passes through the FTS host) since there is no native S3 TPC equivalent.

### End-to-end transfer test with WebDAV

The `scripts/test-webdav.sh` script tests FTS transfers to and from the `rucio/test-webdav` container (Apache + mod_dav with X.509 client cert auth). It runs from the repo root.

#### How WebDAV support works

The gfal2 HTTP plugin uses davix for `davs://` transfers. Two things are required:

- `INSECURE=true` in `config/gfal2_http_plugin.conf` — skips server cert verification for `davs://` transfers. Required because the WebDAV server cert (`CN=webdav`) is signed by `rucio_ca.pem` which is not in the FTS container's system trust store. The client cert is still presented and verified by the server.
- `webdavcert.pem` with `CN=webdav` — the server cert CN must match the Docker hostname `webdav` for connections originating from inside the Docker network.

The WebDAV server still performs `SSLVerifyClient require`, so mutual TLS authentication is enforced even with `INSECURE=true` on the client side.

#### Running the test

```bash
./scripts/test-fts-with-webdav.sh
```

Expected output:
```
=== Waiting for WebDAV ===
  WebDAV ready
=== Verifying WebDAV endpoint ===
  PROPFIND /: HTTP 207

=== WebDAV: xrd1 → WebDAV ===
  Job: f9b78288-2788-11f1-8365-e62107ed9546
  [1] FINISHED
✓ FINISHED

=== WebDAV: WebDAV → xrd2 ===
  Job: fcc730cc-2788-11f1-9247-e62107ed9546
  [1] FINISHED
✓ FINISHED

=== WebDAV: WebDAV → WebDAV (HTTP TPC) ===
  Job: ffd667d8-2788-11f1-9185-e62107ed9546
  [1] FINISHED
✓ FINISHED
```

WebDAV→WebDAV uses HTTP TPC (COPY request) rather than streamed transfer — a genuine third-party copy, unlike the MinIO1→MinIO2 case.

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

### Transfer fails with `no delegated credentials for tpc`

The FTS host certificate is missing the `Key Usage` extension required by XRootD for GSI proxy delegation during TPC. Regenerate `certs/hostcert.pem` with the extension (see Certificates section above) and restart the FTS container.

### `curl` exit code 56 — authenticated request fails, unauthenticated works

Apache received the connection but the TLS handshake failed. The CA certificate was mounted but not yet hashed when Apache started. The entrypoint handles this automatically, but if you see this after a manual `docker run`, run:

```bash
docker exec fts-multiarch-build-fts-1 openssl rehash /etc/grid-security/certificates/
docker exec fts-multiarch-build-fts-1 httpd -k restart
```

### Transfer fails with `SOURCE [52] Failed to stat file (Invalid exchange)`

GSI hostname verification is failing. The XRootD cert uses `CN=xrd` but the client expects the container hostname. This is handled automatically by `XrdSecGSISRVNAMES=*` set in both the entrypoint and XRootD server config.

### Transfer fails with `TRANSFER [52]` during TPC (third-party copy)

The XRootD TPC pull, where xrd2's `xrdcp --server` connects to xrd1, fails hostname verification. This is fixed by `setenv XrdSecGSISRVNAMES = *` in the XRootD server config, which the docker-compose entrypoint appends automatically.

### S3 transfer fails with `HTTP 403 : Permission refused`

Check in order:

1. Confirm `config/gfal2_http_plugin.conf` is mounted and contains `ALTERNATE=true` under `[S3]`.
2. Confirm `ACCESS_KEY` and `SECRET_KEY` match the MinIO credentials (`minioadmin`/`minioadmin` by default).
3. Confirm the storage name registered with FTS is `S3:minio` (not just `minio`).
4. Re-run `docker compose up -d --force-recreate fts` to pick up config file changes.

### WebDAV transfer fails with `SSL handshake failed: tlsv1 alert unknown ca`

The FTS container's davix cannot verify the WebDAV server cert because `rucio_ca.pem` is not in the system trust store. Confirm `INSECURE=true` is set under `[HTTP PLUGIN]` in `config/gfal2_http_plugin.conf` and restart FTS.

### Transfer stuck in ACTIVE

Check the per-transfer log:

```bash
docker exec fts-multiarch-build-fts-1 ls /var/log/fts3/$(date +%Y-%m-%d)/
docker exec fts-multiarch-build-fts-1 cat /var/log/fts3/$(date +%Y-%m-%d)/xrd1__xrd2/<latest-file>
```

### `fts_url_copy` crashes with `Gfal2Exception: /usr/etc/gfal2.d/ is not a valid directory`

Fixed in the Dockerfile by creating a symlink `/usr/etc/gfal2.d -> /etc/gfal2.d`. If you see this in an older image:

```bash
docker exec fts-multiarch-build-fts-1 bash -c 'mkdir -p /usr/etc && ln -s /etc/gfal2.d /usr/etc/gfal2.d'
```

## Known limitations

- `mod_gridsite` is not available in this source build — X.509 proxy certificate delegation is disabled. Standard certificate authentication via `mod_ssl` (`SSL_CLIENT_CERT`) is fully functional.
- The FTS3 REST frontend (`fts-rest-flask`) is installed from source at `/tmp/fts-rest-flask` rather than via RPM, as the official DMC repository does not provide arm64 packages.
- XRootD GSI hostname verification is disabled via `XrdSecGSISRVNAMES=*` because test certificates use `CN=xrd` rather than the full container hostname. This is acceptable for local development but should not be used in production.
- `rucio/test-webdav` is x86_64 only and runs under QEMU emulation on arm64. Server cert verification is disabled (`INSECURE=true`) on the FTS side because the WebDAV CA is not in the FTS container's system trust store.

## References

- Official test-fts image (x86_64, RPM-based): https://github.com/rucio/containers/tree/master/test-fts
- Official FTS3 Dockerfile: https://gitlab.cern.ch/fts/fts3/-/blob/3.14.x-release/packaging/docker/Dockerfile
- fts-rest-flask (REST frontend): https://gitlab.cern.ch/fts/fts-rest-flask
- rucio/k8s-tutorial: https://github.com/rucio/k8s-tutorial