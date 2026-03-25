# Storage Integration Testing

This document covers end-to-end transfer tests that validate Rucio → FTS3 → storage communication for each supported protocol. All tests run from the repo root after `docker compose up -d`.

The test stack covers three storage backends:

| Backend | Container(s) | Protocol | Transfer mode |
|---|---|---|---|
| XRootD | `xrd1`, `xrd2` | `root://` | XRootD TPC (server-side) |
| S3 / MinIO | `minio1`, `minio2` | `s3://` | Streamed (no native S3 TPC) |
| WebDAV | `webdav1`, `webdav2` | `davs://` | Streamed (`DEFAULT_COPY_MODE=streamed`) |

> **WebDAV TPC note:** `rucio/test-webdav` (Apache `mod_dav`) does not implement the cross-server `COPY` with `Source:` header required for HTTP TPC. WebDAV→WebDAV transfers therefore route through FTS as an intermediary. For genuine WebDAV HTTP TPC, a server such as StoRM WebDAV is required.

---

## XRootD

Tests FTS proxy delegation and XRootD TPC (`xrd1 → xrd2`). Must be run from inside the FTS container where `M2Crypto` is available.

```bash
docker exec fts-multiarch-build-fts-1 bash -c \
  'FTS=https://fts:8446 python3 /scripts/test-fts-with-xrootd.py'
```

A seed file is created automatically when xrd1 starts. To test with additional files, copy them into xrd1 first:

```bash
docker exec fts-multiarch-build-xrd1-1 bash -c \
  'echo "my-data" > /rucio/my-file && chown xrootd:xrootd /rucio/my-file'
```

Then run the test with overriden source and destination as needed:

```bash
docker exec fts-multiarch-build-fts-1 bash -c \
  'FTS=https://fts:8446 SRC=root://xrd1//rucio/my-file DST=root://xrd2//rucio/my-file \
   python3 /scripts/test-fts-with-xrootd.py'
```

**Environment variables:**

| Variable | Default | Description |
|---|---|---|
| `FTS` | `https://localhost:8446` | FTS3 endpoint |
| `CERT` | `/etc/grid-security/hostcert.pem` | Client certificate |
| `KEY` | `/etc/grid-security/hostkey.pem` | Client private key |
| `SRC` | `root://xrd1//rucio/fts-test-file` | Transfer source |
| `DST` | `root://xrd2//rucio/fts-test-file` | Transfer destination |

**Expected output:**
```
=== Step 1: connect and delegate ===
  DN:      /CN=fts
  is_root: True
  Delegation OK
=== Step 2: submit transfer ===
  root://xrd1//rucio/fts-test-file -> root://xrd2//rucio/fts-test-file
  Job ID: d33ae870-...
=== Step 3: poll job status ===
  [  5s] FINISHED
✓ Transfer FINISHED successfully
```

---

## S3 / MinIO

Tests FTS transfers to and from MinIO (`xrd1 → minio1`, `minio1 → xrd2`, `minio1 → minio2`). S3 credentials are registered with FTS and signing is handled by davix via `config/gfal2_http_plugin.conf`.

```bash
./scripts/test-fts-with-s3.sh 
```

**Expected output:**
```
=== S3: xrd1 → MinIO1 ===
  [1] FINISHED
✓ FINISHED

=== S3: MinIO1 → xrd2 ===
  [1] FINISHED
✓ FINISHED

=== S3: MinIO1 → MinIO2 (streamed, no native TPC) ===
  [1] FINISHED
✓ FINISHED
```

---

## WebDAV

Tests FTS transfers to and from `rucio/test-webdav` containers (Apache + mod_dav, X.509 client cert auth).

```bash
./scripts/test-fts-with-webdav.sh
```

**Expected output:**
```
=== WebDAV: xrd1 → WebDAV1 ===
  [1] FINISHED
✓ FINISHED

=== WebDAV: WebDAV1 → xrd2 ===
  [1] FINISHED
✓ FINISHED
```