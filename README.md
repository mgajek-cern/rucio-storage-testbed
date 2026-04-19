# rucio-storage-testbed

Multi-architecture Rucio + FTS3 integration testbed with XRootD, WebDAV, S3, StoRM WebDAV and Keycloak OIDC authentication. Enables end-to-end transfer testing on both `linux/amd64` and `linux/arm64`, including Apple Silicon Macs.

## Quick start

```bash
# 1. Generate certificates (includes StoRM trust anchors and JVM cacerts)
./scripts/generate-certs.sh

# 2. Start the stack
docker compose up -d

# 3. Bootstrap Rucio (accounts, RSEs, OIDC identities, token providers)
./scripts/bootstrap-testbed.sh

# 4. Run transfer tests
./scripts/test-rucio-transfers.sh
./scripts/test-fts-with-storm-webdav.sh
```

## Stack

| Service | Description | Port |
|---|---|---|
| `fts` | FTS3 transfer server (GSI proxy auth, multi-arch) | 8446 |
| `fts-oidc` | FTS3 transfer server (OIDC bearer token auth) | 8447 |
| `rucio` | Rucio server — userpass auth | 8445 |
| `rucio-oidc` | Rucio server — OIDC auth via Keycloak | 8448 |
| `keycloak` | OIDC identity provider (token exchange enabled) | 8443 |
| `xrd1` / `xrd2` | XRootD storage endpoints | 1094 / 1095 |
| `webdav1` / `webdav2` | WebDAV storage endpoints (Apache mod_dav) | 443 / 444 |
| `minio1` / `minio2` | S3-compatible storage | 9000 / 9002 |
| `storm1` / `storm2` | StoRM WebDAV (HTTP TPC + OIDC token auth) | 8440 / 8441 |

## Accounts

| Account | Auth | Instance |
|---|---|---|
| `ddmlab` / `secret` | userpass (admin) | `rucio` |
| `jdoe` / `secret` | userpass | `rucio` |
| `jdoe2` / `secret` | OIDC via Keycloak (`/rucio/users`, `/atlas/users`) | `rucio-oidc` |
| `adminuser` / `admin123` | OIDC via Keycloak (`/rucio/admins`, `/atlas/production`) | `rucio-oidc` |

## Tests

```bash
./scripts/test-fts-with-xrootd.py   # FTS + XRootD TPC (GSI proxy)
./scripts/test-fts-with-s3.sh       # FTS + S3/MinIO
./scripts/test-fts-with-webdav.sh   # FTS + WebDAV (Apache mod_dav)
./scripts/test-fts-with-storm-webdav.sh # fts-oidc + StoRM WebDAV HTTP TPC (OIDC token)
./scripts/test-rucio-transfers.sh   # Rucio end-to-end (userpass + OIDC)
```

## Documentation

- [docs/certificates.md](docs/certificates.md) — Certificate generation and trust anchor setup
- [docs/oidc-setup.md](docs/oidc-setup.md) — OIDC configuration (Keycloak, fts-oidc, StoRM)
- [docs/storage-integration-testing.md](docs/storage-integration-testing.md) — Storage test guide
- [docs/fts-multiarch-build.md](docs/fts-multiarch-build.md) — FTS3 multi-arch image build

## TODO

- [x] Bearer token delegation from rucio-oidc conveyor to fts-oidc for STORM RSEs (pending Rucio version support for OIDC token forwarding in conveyor)
- [x] XRootD SciTokens: add xrd3/xrd4 with xrootd-scitokens plugin for full bearer token TPC on `root://` protocol
- ~~[ ] intertwin/teapot: evaluate as a multi-tenancy StoRM WebDAV front-end for WLCG token scenarios~~
- [ ] k8s tutorial — map and organize knowledge within the forked repository

## References

- [rucio/containers — test-fts](https://github.com/rucio/containers/tree/master/test-fts)
- [rucio/k8s-tutorial](https://github.com/rucio/k8s-tutorial)
- [FTS3](https://gitlab.cern.ch/fts/fts3)
- [StoRM WebDAV](https://github.com/italiangrid/storm-webdav)
- [RFC 2518 (WebDAV)](https://datatracker.ietf.org/doc/html/rfc2518)
- [WLCG Bearer Token Profile](https://zenodo.org/records/3526985)
