# ROADMAP

## Phase 1: Hardening & SDK Reference

- [x] **Manual Registration Reference:** Documents the three Python client
  registration patterns via `rucio.client.Client`: bare replica
  (`add_replicas`), atomic dataset creation with files (`add_dataset`),
  and appending to an existing dataset (`add_files_to_dataset`).
  See [user-workflows.md](./docs/user-workflows.md).
- [x] **Cloud-Native Dev Environment:** `.devcontainer` setup with a kind
  cluster pre-wired for local k8s development, and Helm charts covering
  the full Rucio + FTS + Storage (XRootD, WebDAV, StoRM, MinIO) + OIDC
  (Keycloak) stack, mirroring the compose topology on Kubernetes.
- [x] **Bash → Pytest Migration:** All FTS-level and Rucio E2E tests
  migrated to self-contained pytest suites running inside service
  containers; shared infrastructure helpers extracted into `testbed.py`.

## Phase 2: Failure Mode Injection

The goal is to validate error-handling paths, not just happy paths. All
three scenarios are implementable with existing `testbed.py` helpers and
no new tooling dependencies.

- [ ] **Checksum Mismatch Injection**
  Seed a file with known content, register it in Rucio with a deliberately
  wrong `adler32`, add a replication rule, run daemons, assert the rule
  enters STUCK state (`locks_stuck_cnt > 0`) and the stuck lock reason
  contains a checksum-related message.
  - Tooling: `seed_file` + `register_replica` from `testbed.py` with a
    corrupted checksum argument; `validate_rule` already surfaces stuck
    lock details via `list_replica_locks`.
  - Value: validates Rucio's integrity-checking path end to end without
    any new infrastructure.

- [ ] **Token Expiry Mid-Transfer**
  Set Keycloak `accessTokenLifespan` to 60s via the Admin REST API in a
  pytest fixture, submit a transfer that takes longer than the token
  lifetime (e.g. a large file or an artificially slowed storage endpoint),
  assert the job still reaches FINISHED — proving the Rucio conveyor and
  FTS OIDC refresh path handle expiry transparently.
  - Tooling: Keycloak Admin REST API (`PUT /admin/realms/rucio`);
    `poll_fts_job_http` from `testbed.py`; restore token lifetime in
    fixture teardown.
  - Value: directly tests the token refresh loop in `fts3rest` and the
    Rucio conveyor — the most operationally critical OIDC failure mode.

- [ ] **Source Replica Unavailability**
  Stop the source storage container/pod mid-test (before FTS picks up the
  job), submit a replication rule, run daemons, assert the rule enters
  STUCK or FAILED and the lock reason contains a meaningful storage error
  (not a silent timeout). Restore the service in fixture teardown.
  - Tooling (compose): `docker stop compose-xrd1-1` / `docker start`.
  - Tooling (k8s): `kubectl scale deploy/xrd1 --replicas=0` /
    `--replicas=1`.
  - Value: validates that Rucio surfaces actionable errors when a storage
    endpoint disappears rather than hanging indefinitely; tests the
    conveyor retry and stuck-rule detection path.

## Phase 3: Scale & Observability (Optional)

These items are useful for capacity planning and operational insight but
out of scope for a correctness testbed.

- [ ] **Bulk Transfer Benchmarks:** Submit N-file jobs via the FTS Python
  client and measure throughput. Informational only.
- [ ] **Prometheus / Grafana Integration:** FTS exposes metrics on port
  8449; wire up a scrape config and a minimal dashboard for local
  observability during development.
- [ ] **Network Degradation Simulation:** `tc netem` on the Docker bridge
  to simulate WAN latency and packet loss. Requires `NET_ADMIN` capability
  — not compatible with kind CI runners without privilege escalation.
  Local-only option; not recommended for CI.
