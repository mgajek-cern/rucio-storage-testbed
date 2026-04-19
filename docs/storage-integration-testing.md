# Storage Integration Testing

This document covers end-to-end transfer tests that validate Rucio → FTS3 → storage communication for each supported protocol. All tests run from the repo root after `docker compose up -d`.

The test stack covers four storage backends and two FTS instances:

| Backend | Container(s) | Protocol | Transfer mode | Auth |
|---|---|---|---|---|
| XRootD | `xrd1`, `xrd2` | `root://` | XRootD TPC (server-side) | GSI X.509 proxy |
| S3 / MinIO | `minio1`, `minio2` | `s3://` | Streamed (no native S3 TPC) | S3 signed URLs |
| WebDAV (Apache mod_dav) | `webdav1`, `webdav2` | `davs://` | Streamed (`DEFAULT_COPY_MODE=streamed`) | GSI X.509 |
| StoRM WebDAV | `storm1`, `storm2` | `http://` + `davs://` | HTTP TPC (pull) | OIDC bearer tokens |

Two FTS instances run side by side:

| Instance | Port | Auth model | Purpose |
|---|---|---|---|
| `fts` | 8446 | GSI X.509 (host cert / proxy) | Classic grid transfers (XRootD, WebDAV, S3) |
| `fts-oidc` | 8447 | OIDC bearer tokens (Keycloak) | Token-based transfers (StoRM WebDAV, Rucio OIDC conveyor) |

> **WebDAV TPC note:** `rucio/test-webdav` (Apache `mod_dav`) does not implement the cross-server `COPY` with `Source:` header required for HTTP TPC. WebDAV→WebDAV transfers therefore route through FTS as an intermediary. For genuine WebDAV HTTP TPC with OIDC token forwarding, use the StoRM WebDAV tests below.

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

## WebDAV (Apache mod_dav)

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

---

## fts-oidc OIDC auth check

Before the StoRM WebDAV TPC test, CI verifies that `fts-oidc` accepts Keycloak-issued bearer tokens on its REST API.

```bash
TOKEN=$(docker exec rucio-storage-testbed-fts-oidc-1 curl -sk \
  -u "rucio-oidc:rucio-oidc-secret" \
  -d "grant_type=password&username=jdoe2&password=secret" \
  https://keycloak:8443/realms/rucio/protocol/openid-connect/token \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

curl -sk --cacert certs/rucio_ca.pem \
  -H "Authorization: Bearer $TOKEN" \
  https://localhost:8447/whoami
```

**Expected output:**

```json
{"vos":["rucio"],"delegation_id":"...","user_dn":"...","method":"oauth2",...}
```

The critical field is `"method": "oauth2"` — if it reports `"method": "certificate"` the token was rejected and the request fell back to client-cert auth.

---

## StoRM WebDAV HTTP TPC (OIDC bearer tokens, no GSI)

Tests the full OIDC token flow: fts-oidc submits a TPC job to `storm1 → storm2` with the Keycloak bearer token sent as `TransferHeaderAuthorization`. storm2 validates the JWT against Keycloak's JWKS, then pulls the file from storm1.

```bash
./scripts/test-fts-with-storm-webdav.sh
```

This test uses `http://storm1:8085` (anonymous read, `anonymousReadEnabled=true`) as the TPC source to bypass CANL self-signed cert rejection on the pull side. The destination `davs://storm2:8443` uses bearer-token auth — the full OIDC write path is exercised.

**Expected output:**

```
=== Reachability checks ===
  ✓ storm1 self: HTTP 200
  ✓ storm2 self: HTTP 200
  ✓ storm1→storm2: HTTP 200
  ✓ fts-oidc→storm1: HTTP 200

=== Fetching OIDC token ===
  ✓ token obtained
  iss:    https://keycloak:8443/realms/rucio
  groups: ['/rucio/users', '/atlas/users']

=== Storm TPC: storm1 → storm2 (OIDC token, HTTP source → HTTPS dest) ===
  Job: bff4e426-...
  [1] FINISHED
✓ FINISHED

=== storm2 TPC + token auth log evidence ===
... Pull third-party transfer completed: DONE. ...
    hasAuthorizationHeader: true, ...
```

The `hasAuthorizationHeader: true` line in storm2 logs confirms the bearer token made it through.

---

## Rucio end-to-end tests

The full Rucio pipeline is tested for two paths: the classic GSI XRootD flow and the OIDC StoRM WebDAV flow.

### 1. Bootstrap Rucio

Run once after `docker compose up -d`:

```bash
./scripts/bootstrap-testbed.sh
```

This creates:

- Accounts (`root`, `jdoe`) on `rucio`; (`root`, `ddmlab`, `jdoe2`) on `rucio-oidc`
- Scopes (`test`, `user.jdoe`)
- RSEs with FTS attributes, protocols, distances, and account limits:
  - On `rucio`: `XRD1`, `XRD2`, `WEBDAV1`, `WEBDAV2`, `STORM1`, `STORM2`
  - On `rucio-oidc`: same set, with `oidc_support=True` and `verify_checksum=False` on StoRM RSEs
- `t_token_provider` rows seeded with both slash variants of the issuer URL (fts-oidc requires both)
- Alters `t_token.audience` to NULLable (required for unmanaged tokens)

### 2. Run transfer tests

```bash
./scripts/test-rucio-transfers.sh
```

The script runs two transfer scenarios (controlled by which `run_*` functions are uncommented at the bottom):

#### 2a. XRD1 → XRD2 via GSI (userpass and OIDC accounts)

1. Delegates a GSI proxy to FTS via M2Crypto (required for XRootD TPC)
2. Computes the deterministic PFN for the file on XRD1
3. Seeds the file directly on XRD1 at the deterministic path
4. Registers the replica in the Rucio catalogue
5. Creates a replication rule (XRD1 → XRD2)
6. Runs the conveyor daemons once: judge-evaluator → submitter → poller → finisher
7. Prints rule status and replica listing

Expected state: `OK` with `Locks OK/REPLICATING/STUCK: 1/0/0`.

> The OIDC variant (ddmlab account on `rucio-oidc`) uses the same flow but routes via `fts-oidc`. XRootD's `root://` scheme is not yet in Rucio's `_use_tokens` whitelist (upstream accepts only `davs`), so this path still uses GSI for FTS auth — the XRootD SciTokens demo is tracked as a TODO.

#### 2b. STORM1 → STORM2 via OIDC conveyor

Full OIDC token path — no GSI, no X.509 on the transfer data path:

1. Computes the deterministic PFN on STORM1 (via `lfns2pfns`)
2. Seeds the file directly at `/storage/data/.../storm-file-<ts>` on storm1
3. Pre-creates the destination directory on storm2 (FTS does not `MKCOL`)
4. Registers the replica on STORM1 with the computed PFN
5. Creates a replication rule STORM1 → STORM2
6. Runs the conveyor daemons:
   - Submitter requests a Keycloak token (scope=fts, audience=fts-oidc) and submits to fts-oidc
   - fts-oidc attaches per-file `source_tokens` (scope=storage.read, audience=storm1) and `destination_tokens` (scope=storage.modify storage.read, audience=storm2)
   - `fts_url_copy` performs PROPFIND/MKCOL on storm2 with the bearer token, then COPY with `TransferHeaderAuthorization`
   - storm2 pulls from `http://storm1:8085` (plain HTTP, anon read)
7. Poller transitions the request to `DONE`; finisher marks the replica `AVAILABLE`

Expected state: `OK` with `Locks OK/REPLICATING/STUCK: 1/0/0`.

**Verification queries:**

```bash
# Per-file tokens must be populated (NULL = X.509 fallback)
docker exec rucio-storage-testbed-ftsdb-oidc-1 mysql -ufts -pfts fts -e "
SELECT file_id, LEFT(source_surl,40), src_token_id, dst_token_id
FROM t_file ORDER BY file_id DESC LIMIT 3;"

# storm2 evidence of bearer token receipt
docker logs rucio-storage-testbed-storm2-1 2>&1 \
  | grep -E "TransferFilter|hasAuthorizationHeader" | tail -5
```

See `docs/troubleshooting-oidc-transfers.md` for a layer-by-layer diagnostic guide if this test fails.

---

## CI coverage

The full suite runs in GitHub Actions via `.github/workflows/run-integration-tests.yml`. Reusable workflow called from matrix-based job definitions in `.github/workflows/ci.yml`.

Test order (each step is gated on the previous succeeding):

1. Generate self-signed certs (`scripts/generate-certs.sh`)
2. Start stack (`docker compose up -d`)
3. Wait for storm1/storm2 and import `rucio_ca.pem` into the JVM truststore (needed for StoRM's CANL client to trust the self-signed CA for outbound HTTPS)
4. Wait for FTS, Rucio, Keycloak healthchecks
5. Run `bootstrap-testbed.sh`
6. Wait for fts-oidc REST
7. **fts-oidc OIDC token auth check** (verifies `method=oauth2` on whoami)
8. **XRootD TPC test**
9. **S3 / MinIO test**
10. **WebDAV (mod_dav) test**
11. **StoRM WebDAV HTTP TPC test** (OIDC bearer tokens)
12. **Rucio XRD1→XRD2 + STORM1→STORM2 transfer test**

On failure, logs are dumped for: `fts`, `fts-oidc`, `xrd1`, `xrd2`, `rucio`, `rucio-oidc`, `keycloak`, `webdav1`, `storm1`, `storm2`, `minio1`.

The CI runs on both amd64 and arm64 runners — arm64 uses QEMU to emulate the StoRM WebDAV image (only published for amd64), which is why storm startup has generous wait timeouts (~3 minutes).

---

## Architecture notes

### Why two FTS instances?

`fts` (port 8446) runs the classic GSI stack — host certificate auth, VOMS proxy delegation, X.509 client-cert transfer. Used for XRootD, WebDAV, and S3 tests.

`fts-oidc` (port 8447) runs on the same image but is configured for OIDC bearer token auth (`fts3restconfig-oidc`: `AuthorizedVO=*`, `AllowNonManagedTokens=True`, `AllowedOAuth2IssuerURLs=https://keycloak:8443/realms/rucio`). Used for StoRM WebDAV TPC and the Rucio OIDC conveyor path.

Running them side-by-side lets the testbed demonstrate both auth models without requiring a restart or config swap.

### Why manual replica registration?

The `rucio/rucio-server` image does not include gfal2, so `rucio upload` fails at the physical transfer step. The manual registration workflow seeds the file directly on the source RSE and registers it in the Rucio catalogue, which is the correct approach for externally-staged data.

### Why M2Crypto delegation?

XRootD TPC requires a proper RFC 3820 GSI proxy certificate. The curl-based delegation approach (used in WebDAV tests) produces a self-signed certificate that XRootD rejects. The `fts3.delegate()` call via M2Crypto inside the FTS container produces a valid GSI proxy.

### XRootD gridmap entries

Both xrd1 and xrd2 grant access to:

- `/CN=fts` — FTS host cert (used by conveyor for job submission)
- `/CN=fts/CN=proxy` — GSI proxy derived from FTS host cert (used during TPC)
- `/CN=xrd` — XRootD server cert (used by xrd2 to authenticate to xrd1 during TPC pull)
- `/O=Dummy`, `/O=Dummy/CN=proxy` — WebDAV test certs

### Rucio conveyor configuration

Key `rucio.cfg` settings for FTS submission (GSI path):

```ini
[conveyor]
usercert = /etc/grid-security/hostcert_with_key.pem  # combined cert+key for TLS auth to FTS
cacert   = /etc/grid-security/certificates/rucio_ca.pem
```

Additional settings for the OIDC path (`oidc-server.cfg`):

```ini
[oidc]
idpsecrets = /opt/rucio/etc/idpsecrets.json
issuer = https://keycloak:8443/realms/rucio
expected_audience = rucio-oidc
admin_issuer = rucio-oidc

[conveyor]
allow_user_oidc_tokens = True
poller_oidc_support    = True
default_lifetime       = -1
```

`allow_user_oidc_tokens=True` triggers token forwarding in the submitter; `poller_oidc_support=True` ensures the poller uses OIDC for status queries against fts-oidc.

### Rucio patches

`patches/rucio/fts3.py` and `patches/rucio/constants.py` are mounted into `rucio-oidc` to address two upstream gaps (both covered in detail in `docs/troubleshooting-oidc-transfers.md`):

| Patch | Purpose |
|---|---|
| `constants.py` | Adds `http` to the `davs`/`https` scheme compatibility lists in `BASE_SCHEME_MAP` so `http://` sources can pair with `davs://` destinations (required because StoRM1's TPC read protocol is `http://` to bypass CANL self-signed cert rejection) |
| `fts3.py` | Extends `_use_tokens()` to accept `http`/`https`/`davs` (upstream accepts only `davs`); sets `unmanaged_tokens=True` in `build_job_params` to skip FTS token exchange for client-credentials tokens |

Without these patches: the Rucio conveyor either rejects the transfer at scheme-matching time (`SkipSchemeMismatch`) or submits without per-file tokens, causing FTS to fall back to X.509 and storm2 to reject with `ssl/tls alert certificate_unknown`.

### FTS patches

`patches/fts/middleware.py` and `patches/fts/openidconnect.py` are mounted into `fts-oidc` to fix a trailing-slash mismatch between the providers dict key (slash-normalized by `_load_providers_from_db`) and the `self.clients` dict key (populated from Keycloak discovery, without slash). Without these patches every authenticated request returns HTTP 403.
