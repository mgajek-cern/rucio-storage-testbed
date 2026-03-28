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
docker exec rucio-storage-testbed-fts-1 bash -c \
  'FTS=https://fts:8446 python3 /scripts/test-fts-with-xrootd.py'
```

A seed file is created automatically when xrd1 starts. To test with additional files, copy them into xrd1 first:

```bash
docker exec rucio-storage-testbed-xrd1-1 bash -c \
  'echo "my-data" > /rucio/my-file && chown xrootd:xrootd /rucio/my-file'
```

Then run the test with overriden source and destination as needed:

```bash
docker exec rucio-storage-testbed-fts-1 bash -c \
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

## Rucio end-to-end test (XRD1 → XRD2)

Tests the full Rucio pipeline: replica registration → replication rule → conveyor daemons → FTS TPC transfer.

### 1. Bootstrap Rucio

Run once after `docker compose up -d`:

```bash
./scripts/rucio-init.sh
```

This creates accounts (`root`, `jdoe`), scopes (`test`, `user.jdoe`), RSEs (XRD1, XRD2, WEBDAV1, WEBDAV2) with FTS attributes, protocols, distances, and account limits.

### 2. Run transfer test

```bash
./scripts/test-rucio-transfers.sh
```

The script:
1. Delegates a GSI proxy to FTS via M2Crypto (required for XRootD TPC)
2. Computes the deterministic PFN for the file on XRD1
3. Seeds the file directly on XRD1 at the deterministic path
4. Registers the replica in the Rucio catalogue
5. Creates a replication rule (jdoe account, XRD1 → XRD2)
6. Runs the conveyor daemons once: judge-evaluator → submitter → poller → finisher
7. Prints rule status and replica listing

Expected output:
```
State: OK
Locks OK/REPLICATING/STUCK: 1/0/0
RSE: REPLICA
  XRD1: root://xrd1:1094//rucio/test/.../file-...
  XRD2: root://xrd2:1094//rucio/test/.../file-...
```

## Architecture notes

### Why manual replica registration?

The `rucio/rucio-server` image does not include gfal2, so `rucio upload` fails at the physical transfer step. The manual registration workflow seeds the file directly on XRD1 storage and registers it in the Rucio catalogue, which is the correct approach for externally-staged data.

### Why M2Crypto delegation?

XRootD TPC requires a proper RFC 3820 GSI proxy certificate. The curl-based delegation approach (used in WebDAV tests) produces a self-signed certificate that XRootD rejects. The `fts3.delegate()` call via M2Crypto inside the FTS container produces a valid GSI proxy.

### XRootD gridmap entries

Both xrd1 and xrd2 grant access to:
- `/CN=fts` — FTS host cert (used by conveyor for job submission)
- `/CN=fts/CN=proxy` — GSI proxy derived from FTS host cert (used during TPC)
- `/CN=xrd` — XRootD server cert (used by xrd2 to authenticate to xrd1 during TPC pull)
- `/O=Dummy`, `/O=Dummy/CN=proxy` — WebDAV test certs

### Rucio conveyor configuration

Key `rucio.cfg` settings for FTS submission:

```ini
[conveyor]
usercert = /etc/grid-security/hostcert_with_key.pem  # combined cert+key for TLS auth to FTS
cacert   = /etc/grid-security/certificates/rucio_ca.pem
```

The conveyor also patches `default_lifetime = -1` in `fts3.py` to send `copy_pin_lifetime: -1` in FTS jobs, which prevents FTS from enforcing TPC-only mode independently of the XRootD server config.