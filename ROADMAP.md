# ROADMAP

## Phase 1: Hardening & SDK Reference
- [x] **SDK Integration Patterns:** Provide reference implementations using the `rucio-clients` Python library to mirror [Manual Registration Workflows](./docs/user-workflows.md).
- [ ] **Cloud-Native Dev Environment:** Add a `.devcontainer` setup and provide reference Helm charts for deploying the full Rucio+FTS+OIDC stack on K8s (resembling the manual k8s-tutorial alignment).

## Phase 2: Failure Mode Injection
- [ ] **Token Expiry Tests:** Automate tests for 401 Unauthorized scenarios and Rucio's auto-refresh capabilities using OIDC.
- [ ] **Network Realism:** Use `tc` (traffic control) to simulate high-latency WAN links between storage endpoints.
- [ ] **Checksum Mismatches:** Scripted injection of file corruption to validate Rucio's integrity-checking daemons.
