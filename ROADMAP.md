# ROADMAP

## Phase 1: Hardening & SDK Reference
- [x] **SDK Integration Patterns:** Provide reference implementations using the `rucio-clients` Python library to mirror CLI workflows (Replica registration, Rule creation).
- [ ] **Cloud-Native Dev Environment:** Replace the submodule with a `.devcontainer` setup and provide reference Helm charts for deploying the full Rucio+FTS+OIDC stack on K8s (replacing the manual k8s-tutorial alignment).
- [ ] **OIDC Multi-Tenant Docs:** Document the migration path from static StoRM to Teapot (see ADR 001) for partners requiring UID isolation.

## Phase 2: Failure Mode Injection
- [ ] **Token Expiry Tests:** Automate tests for 401 Unauthorized scenarios and Rucio's auto-refresh capabilities using OIDC.
- [ ] **Network Realism:** Use `tc` (traffic control) to simulate high-latency WAN links between storage endpoints.
- [ ] **Checksum Mismatches:** Scripted injection of file corruption to validate Rucio's integrity-checking daemons.

## Phase 3: Advanced Federation
- [ ] **XRootD Redirectors:** Deploy a global redirector to simulate ATLAS-style data federation.
- [ ] **Tape Simulation:** Implement a "slow-storage" shim for StoRM/WebDAV to simulate TURL staging latencies (Staging/Bring-Online).
