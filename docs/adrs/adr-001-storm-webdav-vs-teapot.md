---
status: amended
date: 2026-05-12
decision-makers: testbed maintainers
consulted: /
informed: /
supersedes: 2026-05-10 (original: defer Teapot adoption)
---

# Run StoRM WebDAV and Teapot side-by-side; keep StoRM as the canonical OIDC transfer path

## Context and Problem Statement

The testbed demonstrates an end-to-end OIDC-authenticated transfer pipeline:
Rucio conveyor → FTS-OIDC → StoRM WebDAV TPC, using Keycloak-issued bearer
tokens. The original implementation uses two statically-configured StoRM
WebDAV v1.12.0 instances (`storm1`, `storm2`) sharing a single POSIX user and
a single storage area.

Teapot (developed in the interTwin project) is a Python/FastAPI orchestrator
that sits in front of StoRM WebDAV and spawns per-user StoRM WebDAV JVM
instances on demand, providing filesystem-level uid isolation and
multi-tenancy. The question is whether to replace the current static StoRM
deployment with a Teapot-based one, keep the current architecture, or run
both side-by-side.

## Decision Drivers

* Current testbed must continue to demonstrate the full OIDC transfer chain
  (Rucio → FTS → StoRM) without regression
* Complexity added to the testbed should be justified by a concrete,
  near-term use case
* Dev-vs-prod migration path must be documented so downstream adopters know
  what to change
* Debugging and onboarding burden for new contributors should stay low
* Multiple OIDC issuers should be supportable (e.g., local Keycloak alongside
  a federated IdP)
* Per-user POSIX uid isolation is not currently required by any planned
  testbed use case, but the testbed should demonstrate it is achievable

## Considered Options

* Keep direct StoRM WebDAV (status quo), document the Teapot migration path
* Replace StoRM WebDAV with Teapot now
* Run both side-by-side in the testbed

## Decision Outcome

Chosen option: **Run both side-by-side**, with `storm1`/`storm2` remaining
the canonical OIDC transfer path and `teapot1`/`teapot2` demonstrating
multi-tenancy as a parallel service.

This supersedes the original decision (2026-05-10) to defer Teapot adoption.
The "run both side-by-side" option was fully implemented across two experiment
branches (`experiment/teapot-integration`, `experiment/teapot-tpc-transfer`)
and merged. The ADR migration estimate of ~9 working days proved accurate.

The canonical transfer path (`storm1` → `storm2`) is preserved unchanged.
Teapot is additive — it does not replace StoRM, it demonstrates what a
multi-tenant deployment looks like on top of the same stack.

### Consequences

* Good, because the working Rucio → FTS → StoRM OIDC transfer path is
  preserved and remains easy to reason about
* Good, because `teapot1`/`teapot2` demonstrate per-user JVM isolation and
  FTS TPC in a multi-tenant context without replacing the canonical path
* Good, because both deployment patterns are directly comparable in the same
  environment
* Good, because the canl trust anchor setup, JVM arg ordering fix, and
  Conscrypt disablement are documented and reusable for future deployments
* Neutral, because configuration surface doubles for WebDAV-related services
* Neutral, because the single `trusted_OP` limitation means each Teapot
  instance supports exactly one OIDC issuer — two deployments are required
  for cross-node TPC
* Bad, because resource footprint grows (two additional Teapot containers +
  two spawned JVMs per test run)
* Bad, because CI runtime grows by ~60s due to the cold-start warm-up cost
  per Teapot instance
* Bad, because Teapot's `teapot.py` has a JVM arg ordering bug that requires
  a bind-mount patch until upstream merges the fix

### Confirmation

Compliance with this decision is confirmed by:

* `./shared/tests/test-fts-with-storm-webdav.py` passes — direct
  FTS-OIDC → StoRM TPC (`make test-storm-oidc`)
* `./shared/tests/test-rucio-transfers.py` with `run_storm_oidc_transfer_test`
  passes — Rucio conveyor → FTS-OIDC → StoRM TPC (`make test-rucio`)
* `./shared/tests/test-fts-with-teapot.py` passes — FTS TPC
  teapot1 → teapot2 (`make test-teapot-tpc`)
* `./shared/tests/test-teapot.py` passes — Teapot WebDAV functional test
  (`make test-teapot`)
* `deploy/compose/docker-compose.yml` contains `storm1`/`storm2` as canonical
  services and `teapot1`/`teapot2` as additive parallel services
* `t_file.src_token_id` and `t_file.dst_token_id` are populated for
  conveyor-submitted transfers (proves OIDC tokens are attached per file)
* Rule state transitions to `OK` with `Locks OK/REPLICATING/STUCK: 1/0/0`
  for STORM1 → STORM2 replication rules

If any of these fail, the decision should be revisited rather than worked
around.

## Pros and Cons of the Options

### Keep direct StoRM WebDAV (status quo)

Current architecture: two static StoRM WebDAV JVMs, shared POSIX user,
Keycloak OIDC, Spring profile configs, WLCG scope-based authorization.

* Good, because the OIDC transfer path has been debugged end-to-end and is
  reproducible
* Good, because StoRM WebDAV supports multiple OIDC issuers natively via
  `oauth.issuers` list
* Good, because the official `ghcr.io/italiangrid/storm-webdav:v1.12.0`
  image is used — no custom packaging
* Good, because startup is deterministic (ports 8443/8085 always, no
  per-request JVM spawn latency)
* Good, because StoRM WebDAV is deployed in production at multiple
  Tier-1/Tier-2 sites
* Neutral, because the TPC pair uses `http://` source (port 8085) +
  `davs://` destination (port 8443), which requires patching Rucio's scheme
  compatibility map — this is a self-signed-cert workaround, not a StoRM
  limitation
* Bad, because there is no per-user POSIX uid isolation — all files owned by
  a single `storm` user
* Bad, because demonstrating multi-tenancy would require running additional
  StoRM containers per tenant, which does not scale

### Replace StoRM WebDAV with Teapot now

Teapot-based architecture: single Teapot orchestrator, per-user StoRM WebDAV
JVMs spawned on demand, VO group → POSIX username mapping, dynamic port
allocation.

* Good, because per-user JVMs provide filesystem-level uid isolation
* Good, because idle JVMs are torn down automatically after
  `INSTANCE_TIMEOUT_SEC`, reducing long-running memory footprint for sparse
  multi-tenant workloads
* Good, because it matches the interTwin reference pattern for multi-tenant
  StoRM deployments
* Neutral, because token validation, scope-based authz, and TPC support are
  delegated to StoRM — so the auth semantics are identical
* Bad, because Teapot supports only a single `trusted_OP` per instance;
  supporting multiple IdPs requires multiple Teapot deployments
* Bad, because dynamic port allocation (32400+) complicates Rucio RSE URL
  construction
* Bad, because the first request from a new user pays a ~30–60s JVM spawn
  cost, which is incompatible with CI timeouts without careful warm-up tuning
* Bad, because re-validating the Rucio conveyor integration, FTS audience
  resolution, and TPC flow would invalidate the current testbed's
  proven-working state

### Run both side-by-side ✓ chosen

Keep `storm1` + `storm2` and add `teapot1` + `teapot2` alongside, registering
separate `TEAPOT1` / `TEAPOT2` RSEs.

* Good, because it preserves the existing working tests while adding the
  multi-tenancy demonstration
* Good, because it supports direct comparison of the two deployment patterns
  in the same environment
* Good, because FTS TPC between teapot1 and teapot2 validates a real
  cross-node multi-tenant transfer
* Neutral, because it doubles the WebDAV-related configuration surface
* Bad, because resource footprint grows (two additional Teapot containers +
  two spawned JVMs per test run)
* Bad, because CI runtime grows due to the ~30s first-spawn warm-up cost per
  Teapot instance

## More Information

**When this decision should be revisited:**

* A concrete use case requires replacing StoRM with Teapot as the canonical
  path (per-user uid isolation, regulatory audit trails, etc.)
* A downstream adopter needs Teapot as the primary storage endpoint rather
  than a demonstration service
* Teapot reaches a release state where multi-issuer support and stable-port
  reverse-proxy deployment are documented and tested
* Upstream Teapot merges the JVM arg ordering fix, removing the need for the
  bind-mount patch

**Known upstream issues to track:**

* `teapot.py` JVM arg ordering bug — all `-D` flags and `-X` heap options
  placed after `-jar` are silently ignored as application args rather than
  JVM options. Worked around via bind-mount patch at
  `shared/patches/teapot/teapot.py`. Should be upstreamed to
  interTwin-eu/teapot.
* Conscrypt TPC path bypasses canl trust anchors — `TPC_USE_CONSCRYPT=false`
  required in `config.ini`. Worth filing upstream as a documentation issue.

**canl trust anchor requirements (applies to all Storm-WebDAV deployments):**

Both the new and old OpenSSL CA hash variants (`5fca1cb1.0` / `b96dc756.0`)
and their signing policies must be present in `/etc/grid-security/certificates`.
`canl`'s `OpensslCertChainValidator` silently fails to load a trust anchor if
only one hash variant is present. The JVM truststore (`storm-cacerts`) must
also be mounted separately for outbound HTTPS connections (OIDC discovery,
JWKS fetching) — this is distinct from the canl trust anchors directory.

**Image availability:** The testbed uses `mgajekcern/teapot:latest` as a
publicly accessible mirror of the interTwin image. The official
`ghcr.io/intertwin-eu/teapot:latest` requires interTwin org credentials.

**References:**

* StoRM WebDAV: <https://github.com/italiangrid/storm-webdav>
* Teapot: <https://github.com/interTwin-eu/teapot>
* Teapot installation guide: <https://intertwin-eu.github.io/teapot/installation-guide/>
* Teapot configuration reference: <https://github.com/interTwin-eu/teapot/blob/main/CONFIGURATION.md>
