# ROADMAP

## Phase 1: Hardening & K8s Transition
* **K8s Tutorial Alignment:** Port Docker Compose logic into Helm charts for the `rucio/k8s-tutorial` repository.
* **OIDC Multi-Tenant Docs:** Document the migration path from static StoRM to Teapot (see ADR 001).

## Phase 2: Failure Mode Injection
* **Token Expiry Tests:** Automate tests for 401 Unauthorized scenarios and Rucio's auto-refresh capabilities.
* **Network Realism:** Use `tc` (traffic control) to simulate high-latency WAN links between storage endpoints.
* **Checksum Mismatches:** Scripted injection of file corruption to validate Rucio's integrity-checking daemons.

## Phase 3: Advanced Federation
* **XRootD Redirectors:** Deploy a global redirector to simulate ATLAS-style data federation.
* **Tape Simulation:** Implement a "slow-storage" shim for StoRM/WebDAV to simulate TURL staging latencies.
