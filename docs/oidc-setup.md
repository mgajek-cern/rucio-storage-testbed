# OIDC Setup

This document describes the OIDC token authentication flow in the testbed: Keycloak → fts-oidc → StoRM WebDAV.

## Overview

```
jdoe2 ──► Keycloak ──► fts-oidc REST API ──► fts_url_copy ──► StoRM WebDAV
          (issues)      (validates token)     (token exchange)  (validates token)
```

The OIDC path replaces the traditional GSI proxy delegation used by the classic `fts` instance. No X.509 client certificates are required for storage access.

## Keycloak

**Realm:** `rucio`  
**URL:** `http://localhost:8080/realms/rucio`  
**Admin:** `admin` / `admin`

The realm is imported from `config/keycloak/realm.json` on startup. Key settings:

- `--features=token-exchange` — required for FTS-OIDC token exchange flow
- `accessTokenLifespan: 3600` — 1-hour token lifetime
- `refreshTokenMaxReuse: 1` — enables token exchange

### Client: `rucio-oidc`

Confidential client used by both rucio-oidc and fts-oidc.

| Setting | Value |
|---|---|
| Client ID | `rucio-oidc` |
| Client Secret | `rucio-oidc-secret` |
| Grant types | password, client_credentials, token_exchange |
| Default scopes | `openid`, `profile`, `email`, `wlcg` |

The `wlcg` client scope adds:
- `wlcg.ver: "1.0"` — WLCG profile version
- `wlcg.groups` — full-path group membership (e.g. `/rucio/users`, `/atlas/users`)

An audience mapper adds `aud: rucio-oidc` to all access tokens (required for FTS token storage in `t_token`).

### Groups

| Group | Members |
|---|---|
| `/rucio/users` | jdoe2 |
| `/rucio/admins` | adminuser |
| `/atlas/users` | jdoe2 |
| `/atlas/production` | adminuser |

### Fetch a token manually

```bash
curl -sk -u "rucio-oidc:rucio-oidc-secret" \
  -d "grant_type=password&username=jdoe2&password=secret" \
  http://localhost:8080/realms/rucio/protocol/openid-connect/token \
  | python3 -c "import sys,json; t=json.load(sys.stdin); print(t['access_token'])"
```

## fts-oidc

The `fts-oidc` service (`mgajekcern/test-fts`) runs a separate FTS instance configured for OIDC bearer token authentication only — no GSI proxy support.

**REST API:** `https://localhost:8447`  
**Config:** `config/fts3restconfig-oidc`, `config/fts3config-oidc`

### Patched files (volume-mounted)

Two upstream bugs are fixed via bind-mounted Python files:

| File | Bug fixed |
|---|---|
| `config/fts3rest-middleware.py` | `_load_providers_from_db()` added trailing slash to issuer URL in providers dict key, causing FK violation on `t_token` insert |
| `config/fts3rest-openidconnect.py` | `get_token_issuer()` added trailing slash to raw `iss` claim, causing `token_issuer_supported()` to return false for all tokens |

Both bugs produced a mismatch between the providers dict key (slash-normalized) and the `self.clients` dict key (from Keycloak discovery, no slash), resulting in HTTP 403 on every authenticated request.

### Token provider registration

fts-oidc requires a row in `t_token_provider` for each trusted issuer. `rucio-init.sh` inserts both slash variants to satisfy the FK constraint:

```sql
INSERT IGNORE INTO t_token_provider (name, issuer, client_id, client_secret)
VALUES
  ('keycloak-rucio',       'http://keycloak:8080/realms/rucio',  'rucio-oidc', 'rucio-oidc-secret'),
  ('keycloak-rucio-slash', 'http://keycloak:8080/realms/rucio/', 'rucio-oidc', 'rucio-oidc-secret');
```

The `t_token.audience` column is made nullable because Keycloak Community Edition tokens have no `aud` claim by default:

```sql
ALTER TABLE t_token MODIFY COLUMN audience varchar(1024) NULL;
```

### Verify authentication

```bash
TOKEN=$(docker exec rucio-storage-testbed-fts-oidc-1 curl -sk \
  -u "rucio-oidc:rucio-oidc-secret" \
  -d "grant_type=password&username=jdoe2&password=secret" \
  http://keycloak:8080/realms/rucio/protocol/openid-connect/token \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

curl -sk --cacert certs/rucio_ca.pem \
  -H "Authorization: Bearer $TOKEN" \
  https://localhost:8447/whoami
# Expected: "method": "oauth2"
```

## StoRM WebDAV

storm1 and storm2 use Spring Security with OIDC token validation. Configuration is split across two Spring profile files mounted at `/app/`:

| File | Content |
|---|---|
| `config/storm-application-issuers.yml` | Trusted OIDC issuer (Keycloak) |
| `config/storm-application-policies.yml` | Fine-grained authz policies + TPC config |
| `config/data.properties` | Storage area `data` configuration |

Activated via: `-Dspring.profiles.active=issuers,policies`

### Authorization policy

```yaml
storm:
  authz:
    policies:
      - sa: data
        actions: [all]
        effect: permit
        principals:
          - type: any-authenticated-user   # any valid Keycloak token
      - sa: data
        actions: [list, read]
        effect: permit
        principals:
          - type: anyone                   # anonymous read (for HTTP TPC source)
```

### TPC transfer flow

FTS-OIDC uses token exchange (Keycloak `--features=token-exchange`) to obtain a scoped token for the destination, then sends it as `TransferHeaderAuthorization` in the WebDAV COPY request. storm2 uses this token to authenticate to storm1 for the pull.

In this testbed, the source URL uses plain HTTP (`http://storm1:8085/`) to bypass CANL TLS validation of self-signed certificates. The destination still uses HTTPS (`davs://storm2:8443/`).

### CANL trust anchors

StoRM's TPC HTTP client uses CANL (`eu.emi.security.authn.x509`) for TLS validation, which requires:

1. `certs/trustanchors/` — OpenSSL rehash directory with `5fca1cb1.0 -> rucio_ca.pem` symlink (created by `generate-certs.sh` using Docker on macOS)
2. `certs/storm-cacerts` — JVM cacerts with rucio CA imported (created by `generate-certs.sh` using `keytool` inside the storm image)

Both are bind-mounted into storm1/storm2 at runtime.