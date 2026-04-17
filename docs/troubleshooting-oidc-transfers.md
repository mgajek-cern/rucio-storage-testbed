# Troubleshooting: Rucio → FTS → StoRM OIDC Transfer Pipeline

Verify each layer bottom-up. Stop at the first failure — later layers depend on earlier ones.

## 0. Stack is up and healthy

```bash
docker compose ps --filter "status=running" --format 'table {{.Name}}\t{{.State}}\t{{.Status}}'
```

All of keycloak, fts-oidc, rucio-oidc, storm1, storm2 must be `healthy`. If any are unhealthy, `docker logs <container>` and fix before continuing.

## 1. Keycloak is reachable and can issue tokens

```bash
docker exec rucio-storage-testbed-rucio-oidc-1 curl -sf \
  http://keycloak:8080/realms/rucio/.well-known/openid-configuration \
  | jq -r .issuer
```

Expect: `http://keycloak:8080/realms/rucio`. If 404, Keycloak hasn't imported the realm — check `./config/keycloak/realm.json` mount and logs.

## 2. Client credentials grant works

```bash
docker exec rucio-storage-testbed-rucio-oidc-1 curl -s \
  -u "rucio-oidc:rucio-oidc-secret" \
  -d "grant_type=client_credentials&scope=fts" \
  http://keycloak:8080/realms/rucio/protocol/openid-connect/token \
  | jq -r '.access_token // .error_description'
```

A JWT string means OK. `invalid_scope` means the scope isn't registered as a client scope in the realm.

## 3. Storage-scoped tokens (WLCG path-suffixed scopes)

This is where the most time was spent. Keycloak matches scopes **exactly** — `storage.read:/data` must be registered as its own client scope, Rucio does not auto-split the path.

```bash
for scope in "storage.read:/data" "storage.modify:/data"; do
  code=$(docker exec rucio-storage-testbed-rucio-oidc-1 curl -s \
    -u "rucio-oidc:rucio-oidc-secret" \
    -d "grant_type=client_credentials&scope=${scope}" \
    http://keycloak:8080/realms/rucio/protocol/openid-connect/token \
    | jq -r '.error // "OK"')
  echo "  ${scope}: ${code}"
done
```

If any returns `invalid_scope`, add the scope to `realm.json`:

```json
"clientScopes": [
  ...
  { "name": "storage.read:/data", "protocol": "openid-connect" },
  { "name": "storage.modify:/data", "protocol": "openid-connect" }
],
```

And add to the `rucio-oidc` client's `defaultClientScopes` or `optionalClientScopes`. The path suffix must match the RSE prefix — check with:

```bash
docker exec rucio-storage-testbed-rucio-oidc-1 python3 -c "
from rucio.core.rse import determine_scope_for_rse, get_rse_id
print(determine_scope_for_rse(get_rse_id('STORM1'), scopes=['storage.read']))
"
```

Output like `storage.read:/data` tells you the path suffix Keycloak must accept.

Reload: `docker compose rm -sf keycloak && docker compose up -d keycloak`.

## 4. Rucio `request_token` succeeds for all conveyor token kinds

`FTS3Transfertool.__init__` requests one FTS token; `_file_from_transfer` requests one source-storage and one destination-storage token per file. All three must succeed:

```bash
docker exec rucio-storage-testbed-rucio-oidc-1 python3 -c "
from rucio.core.oidc import request_token
from rucio.core.rse import determine_audience_for_rse, determine_scope_for_rse, get_rse_id

print('fts-oidc :', bool(request_token(audience='fts-oidc', scope='fts')))

for rse in ['STORM1', 'STORM2']:
    rid = get_rse_id(rse)
    aud = determine_audience_for_rse(rid)
    if rse == 'STORM1':
        scp = determine_scope_for_rse(rid, scopes=['storage.read'], extra_scopes=['offline_access'])
    else:
        scp = determine_scope_for_rse(rid, scopes=['storage.modify', 'storage.read'], extra_scopes=['offline_access'])
    print(f'{rse:8s}:', bool(request_token(aud, scp)), f'(aud={aud}, scope={scp!r})')
"
```

All must be `True`. If `False`, re-run step 3 with the exact `scope` shown.

## 5. FTS-OIDC accepts the Rucio-issued token

```bash
TOKEN=$(docker exec rucio-storage-testbed-rucio-oidc-1 python3 -c "
from rucio.core.oidc import request_token
print(request_token(audience='fts-oidc', scope='fts'))")

docker exec rucio-storage-testbed-fts-oidc-1 curl -sk \
  -H "Authorization: Bearer $TOKEN" \
  https://localhost:8446/whoami | jq
```

Expect `vos`, `user_dn`, etc. If 403, check `VerifyAudience`/`AllowedOAuth2IssuerURLs` in `fts3restconfig-oidc`. If 500, check the `t_token_provider` table has both slash variants of the issuer.

## 6. StoRM accepts a bearer token

```bash
TOKEN=$(docker exec rucio-storage-testbed-rucio-oidc-1 python3 -c "
from rucio.core.oidc import request_token
print(request_token(audience='storm2', scope='storage.modify:/data storage.read:/data'))")

docker exec rucio-storage-testbed-storm1-1 curl -sk \
  --capath /etc/grid-security/certificates \
  -H "Authorization: Bearer $TOKEN" \
  -X PROPFIND -H "Depth: 1" \
  https://storm2:8443/data/ -o /dev/null -w '%{http_code}\n'
```

Expect `207`. If `401`/`500`, storm2 can't validate the JWT — check the Keycloak JWKS reachability and that `application-issuers.yml` lists `http://keycloak:8080/realms/rucio` as a trusted issuer.

## 7. End-to-end: Rucio conveyor → FTS → StoRM

With all layers green, submit via the full pipeline:

```bash
./scripts/test-fts-with-storm-webdav.sh   # FTS↔StoRM direct
./scripts/test-rucio-transfers.sh         # Rucio conveyor path
```

Check the rule progresses past `REPLICATING`:

```bash
rc_oidc() {
  docker exec rucio-storage-testbed-rucio-oidc-1 rucio \
    -S userpass -u ddmlab --password secret \
    --host http://rucio-oidc --auth-host http://rucio-oidc "$@"
}

rc_oidc rule show <rule-id>
rc_oidc replica list file test:<name>
```

Rule state `OK` with `Locks OK/REPLICATING/STUCK: 1/0/0` confirms full success.

## 8. Evidence of OIDC auth on StoRM side

```bash
docker logs rucio-storage-testbed-storm2-1 2>&1 \
  | grep -E "TransferFilter|hasAuthorizationHeader" | tail -5
```

Look for `hasAuthorizationHeader: true` and `Pull third-party transfer completed: DONE` — proves the bearer token made it through and was accepted.

## Quick reference: what each layer fails with

| Symptom | Layer | Fix |
|---|---|---|
| `invalid_scope` | 3 | Add scope to realm.json, restart Keycloak |
| `request_token` returns `None`/`False` | 4 | Usually a scope issue from layer 3 |
| FTS whoami 403 | 5 | `VerifyAudience=False`, check issuer URL slash variants |
| FTS submit "Unmanaged tokens not allowed" | 5 | `AllowNonManagedTokens=True` in fts3restconfig |
| FTS submit "Token for source missing" | 5 | Pass real token (not null) and `unmanaged_tokens: true` |
| StoRM 401 with valid token | 6 | JWKS not cached — wait 60s or check `OAUTH_ISSUERS_REFRESH_PERIOD` |
| StoRM TPC fails with TLS handshake | 6 | CANL rejects self-signed CA — use HTTP source (port 8085) |
| Rule stuck in `REPLICATING` | 7 | Check conveyor-poller logs; usually FTS job state |

## Notes on Keycloak token exchange

The manual `grant-type:token-exchange` test returning `access_denied` for cross-client audiences is **not a blocker** — Rucio's conveyor uses `client_credentials` (not token exchange) to obtain all three tokens. If you need true token exchange later (e.g., for user-delegated tokens), enable per-target-client permissions in Keycloak. For this testbed, `client_credentials` + `unmanaged_tokens=true` on FTS sidesteps the entire exchange machinery.