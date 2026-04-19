# Certificate Setup

Certificates are **not** baked into the image. They are provided at runtime via volume mounts (docker-compose) or Kubernetes Secrets.

The CA certificate must be mounted at the OpenSSL hash path. `rucio_ca.pem` from `k8s-tutorial/secrets/` has hash `5fca1cb1`, so it must be mounted as `5fca1cb1.0`.

## Generating certificates for local testing

Run the bundled script (requires `certs/rucio_ca.pem` and `certs/rucio_ca.key.pem`):

```bash
./scripts/generate-certs.sh
```

This produces, all signed by the Rucio CA:

| File | Subject | SANs | Used by |
|---|---|---|---|
| `hostcert.pem` + `hostkey.pem` | `/CN=fts` | `fts, fts-oidc, localhost` | FTS / FTS-OIDC TLS, Rucio conveyor client auth |
| `hostcert_with_key.pem` | combined PEM | — | `[conveyor] usercert` (cert+key in one file) |
| `xrdcert.pem` + `xrdkey.pem` | `/CN=xrd-storage` | `xrd1, xrd2, xrd3, xrd4, localhost` | All four XRootD containers (shared) |
| `storm{1,2}cert.pem` + key | `/CN=storm{1,2}` | `storm{1,2}, localhost` | StoRM WebDAV TLS |
| `webdav{1,2}cert.pem` + key | `/CN=webdav{1,2}` | `webdav{1,2}, localhost` | Apache mod_dav TLS |
| `5fca1cb1.{signing_policy,namespaces}` | — | — | CANL trust store for StoRM TPC client |
| `storm-cacerts` | — | — | JVM truststore with rucio CA imported |

## Important notes

- **All server certs include `subjectAltName` extensions.** Modern TLS clients (gfal2/Neon, davix, OpenSSL ≥3.0) reject CN-only matching and require SANs. The script verifies SANs after each cert is generated.
- **The XRootD cert is shared across all four containers** (`xrd1..xrd4`) via a multi-SAN cert. This matches WLCG production patterns and means one cert/key to rotate.
- **`hostcert_with_key.pem`** (cert + key concatenated) is required by the Rucio conveyor daemon (`[conveyor] usercert`) to authenticate TLS connections to FTS.
- **`XrdSecGSISRVNAMES`** is no longer needed — the XRootD cert's SANs cover the actual container hostnames, so standard TLS hostname verification works.
- **macOS**: the script auto-detects LibreSSL (shipped at `/usr/bin/openssl`) and uses LibreSSL-compatible commands for SAN verification.

## Restart after regeneration

```bash
docker compose restart xrd1 xrd2 xrd3 xrd4 webdav1 webdav2 storm1 storm2 fts fts-oidc
```
