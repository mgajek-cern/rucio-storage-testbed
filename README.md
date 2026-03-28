# rucio-storage-testbed

Multi-architecture Rucio + FTS3 integration testbed with XRootD, WebDAV, S3 and Keycloak OIDC authentication. Enables end-to-end transfer testing on both `linux/amd64` and `linux/arm64`, including Apple Silicon Macs.

## Quick start

```bash
# 1. Generate certificates
./scripts/generate-certs.sh   # see docs/certificates.md for manual steps

# 2. Start the stack
docker compose up -d

# 3. Bootstrap Rucio (accounts, RSEs, OIDC identities)
./scripts/rucio-init.sh

# 4. Run transfer tests
./scripts/test-rucio-transfers.sh
```

## Stack

| Service | Description | Port |
|---|---|---|
| `fts` | FTS3 transfer server (multi-arch) | 8446 |
| `rucio` | Rucio server — userpass auth | 8445 |
| `rucio-oidc` | Rucio server — OIDC auth via Keycloak | 8448 |
| `keycloak` | OIDC identity provider | 8080 |
| `xrd1` / `xrd2` | XRootD storage endpoints | 1094 / 1095 |
| `webdav1` / `webdav2` | WebDAV storage endpoints | 443 / 444 |
| `minio1` / `minio2` | S3-compatible storage | 9000 / 9002 |

## Accounts

| Account | Auth | Instance |
|---|---|---|
| `ddmlab` / `secret` | userpass (admin) | `rucio` |
| `jdoe` / `secret` | userpass | `rucio` |
| `jdoe2` / `secret` | OIDC via Keycloak | `rucio-oidc` |

## Tests

```bash
./scripts/test-fts-with-xrootd.py   # FTS + XRootD TPC
./scripts/test-fts-with-s3.sh       # FTS + S3/MinIO
./scripts/test-fts-with-webdav.sh   # FTS + WebDAV
./scripts/test-rucio-transfers.sh   # Rucio end-to-end (userpass + OIDC)
```

## Documentation

- [docs/certificates.md](docs/certificates.md) — Certificate generation
- [docs/storage-integration-testing.md](docs/storage-integration-testing.md) — Storage test guide
- [docs/fts-multiarch-build.md](docs/fts-multiarch-build.md) — FTS3 multi-arch image build

## TODO

- [ ] Complete OIDC setup including a second FTS instance configured with OIDC tokens (current OIDC test authenticates jdoe2 to Rucio via Keycloak but the conveyor still delegates GSI/x509 to FTS — true OIDC TPC requires FTS bearer token support
and XRootD configured to accept WLCG tokens)
- [ ] StoRM-WebDAV integration (intertwin/teapot)
- [ ] k8s tutorial — map and organize knowledge within the forked repository

## References

- [rucio/containers — test-fts](https://github.com/rucio/containers/tree/master/test-fts)
- [rucio/k8s-tutorial](https://github.com/rucio/k8s-tutorial)
- [FTS3](https://gitlab.cern.ch/fts/fts3)
- [RFC-2518 (WebDAV)](https://datatracker.ietf.org/doc/html/rfc2518)