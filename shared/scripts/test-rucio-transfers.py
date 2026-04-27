#!/usr/bin/env python3
"""
Python equivalent of test-rucio-transfers.sh — runs the same three scenarios
(XRootD GSI, StoRM OIDC, XRootD OIDC) using the Rucio Python client.

Runtime-agnostic: respects $RUNTIME (compose | k8s, default compose).

Typical invocations:
    docker exec compose-rucio-client-1 \\
        bash -c "pytest -v /scripts/test-rucio-transfers.py"

    kubectl -n rucio-testbed exec deploy/rucio-client -- \\
        bash -c "RUNTIME=k8s pytest -v /scripts/test-rucio-transfers.py"

GSI test is skipped automatically on k8s (see KNOWN_ISSUES.md). Set SKIP_GSI=1
to skip it on compose too, or SKIP_GSI=0 to force-run on k8s.
"""

import logging
import os
import re
import subprocess
import time
import zlib

import pytest

from rucio.client import Client
from rucio.common.config import get_config
from rucio.common.exception import Duplicate, RucioException, RuleNotFound
from rucio.rse import rsemanager as rsemgr


log = logging.getLogger("rucio-transfers")


# ── Runtime detection ──────────────────────────────────────────────────────
RUNTIME = os.getenv("RUNTIME", "compose")
SKIP_GSI = os.getenv("SKIP_GSI", "")
K8S_NAMESPACE = os.getenv("K8S_NAMESPACE", "rucio-testbed")

# Skip GSI when (a) on k8s and SKIP_GSI not explicitly "0", or (b) SKIP_GSI=1
SHOULD_SKIP_GSI = (RUNTIME == "k8s" and SKIP_GSI != "0") or SKIP_GSI == "1"


# ── Topology (logical service names — no runtime details) ──────────────────
RUCIO = "rucio"
RUCIO_OIDC = "rucio-oidc"
XRD1, XRD2, XRD3, XRD4 = "xrd1", "xrd2", "xrd3", "xrd4"
STORM1, STORM2 = "storm1", "storm2"
FTS = "fts"

CFG_STD = "/opt/rucio/etc/userpass-client.cfg"
CFG_OIDC = "/opt/rucio/etc/userpass-client-for-rucio-oidc.cfg"

# Maps logical service name → k8s target spec.
# (kind, container_name); container=None means no -c flag.
K8S_TARGETS = {
    "rucio": ("deploy", "rucio"),
    "rucio-oidc": ("deploy", "rucio-oidc"),
    "fts": ("deploy", None),
    "fts-oidc": ("deploy", None),
    "xrd1": ("deploy", None),
    "xrd2": ("deploy", None),
    "xrd3": ("deploy", None),
    "xrd4": ("deploy", None),
    "storm1": ("statefulset", None),
    "storm2": ("statefulset", None),
    "webdav1": ("deploy", None),
    "webdav2": ("deploy", None),
}


# ── Runtime-aware exec helper ──────────────────────────────────────────────
def svc_exec(svc: str, cmd: list, user: str = None) -> bytes:
    if RUNTIME == "compose":
        full = ["docker", "exec"]
        if user:
            full += ["--user", user]
        full += [f"compose-{svc}-1"] + cmd
    elif RUNTIME == "k8s":
        kind, container = K8S_TARGETS.get(svc, ("deploy", None))
        target = f"{kind}/{svc}"
        full = ["kubectl", "-n", K8S_NAMESPACE, "exec"]
        if container:
            full += ["-c", container]
        full += [target, "--"] + cmd
    else:
        raise RuntimeError(f"Unknown RUNTIME: {RUNTIME}")

    result = subprocess.run(full, capture_output=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"svc_exec failed (exit {result.returncode}): {' '.join(full)}\n"
            f"--- stdout ---\n{result.stdout.decode(errors='replace')}\n"
            f"--- stderr ---\n{result.stderr.decode(errors='replace')}"
        )
    return result.stdout


# ── Fixtures ───────────────────────────────────────────────────────────────
def _client(cfg_path: str) -> Client:
    conf = get_config()
    conf.read(cfg_path)
    rucio_host = conf.get("client", "rucio_host")
    c = Client(
        rucio_host=rucio_host,
        auth_host=conf.get("client", "auth_host"),
        account=conf.get("client", "account"),
        auth_type=conf.get("client", "auth_type"),
        creds={
            "username": conf.get("client", "username"),
            "password": conf.get("client", "password"),
        },
        vo=conf.get("client", "vo", fallback="def"),
    )
    log.info(
        "Connected to Rucio at %s (VO: %s, runtime: %s)", rucio_host, c.vo, RUNTIME
    )
    return c


@pytest.fixture(scope="session")
def client_std():
    return _client(CFG_STD)


@pytest.fixture(scope="session")
def client_oidc():
    return _client(CFG_OIDC)


@pytest.fixture(scope="session")
def fts_proxy():
    """Delegate a host-cert proxy to FTS once per test session."""
    log.info("=== Delegating proxy to FTS ===")
    py = (
        "import datetime, fts3.rest.client.easy as fts3\n"
        "ctx = fts3.Context('https://fts:8446', "
        "ucert='/etc/grid-security/hostcert.pem', "
        "ukey='/etc/grid-security/hostkey.pem', verify=False)\n"
        "fts3.delegate(ctx, lifetime=datetime.timedelta(hours=48), force=True)\n"
        "print('Delegation OK - DN:', fts3.whoami(ctx)['user_dn'])"
    )
    out = svc_exec(FTS, ["python3", "-c", py])
    log.info("  %s", out.decode().strip())


# ── Storage helpers ─────────────────────────────────────────────────────────
def compute_metadata_from_storage(storage_svc: str, fpath: str):
    raw = svc_exec(storage_svc, ["cat", fpath])
    size = len(raw)
    if size == 0:
        raise RuntimeError(f"File {fpath} on {storage_svc} is empty or missing")
    adler32 = "%08x" % (zlib.adler32(raw) & 0xFFFFFFFF)
    return size, adler32


def compute_pfn(client: Client, rse: str, scope: str, name: str) -> str:
    rse_info = rsemgr.get_rse_info(rse=rse, vo=client.vo)
    mapping = rsemgr.lfns2pfns(
        rse_info,
        [{"scope": scope, "name": name}],
        operation="write",
    )
    return list(mapping.values())[0]


def pfn_to_local_path(rse: str, pfn: str) -> str:
    if rse.startswith("STORM"):
        return re.sub(r"^[a-z]+://storm[1-2]:[0-9]+/data/", "/storage/data/", pfn)
    s = re.sub(r"^[a-z]+://[^/]+", "", pfn)
    return re.sub(r"^/+", "/", s)


def seed_file(storage_svc: str, fpath: str, owner: str):
    # chown is best-effort — on k8s we can't run as root via kubectl exec,
    # but the chart is expected to set fsGroup so the running user can write.
    script = (
        "set -e; "
        f'mkdir -p "$(dirname {fpath})"; '
        f'printf "rucio-test\\n" > {fpath}; '
        f"chown {owner}:{owner} {fpath} 2>/dev/null || true; "
        f"ls -la {fpath}"
    )
    out = svc_exec(storage_svc, ["sh", "-c", script], user="root")
    log.info("  %s", out.decode().strip())


def prepare_dest_dir(storage_svc: str, fpath: str, owner: str):
    script = (
        f'mkdir -p "$(dirname {fpath})" && '
        f'chown {owner}:{owner} "$(dirname {fpath})" 2>/dev/null || true'
    )
    svc_exec(storage_svc, ["sh", "-c", script], user="root")
    log.info("  ✓ Destination dir ready on %s: %s", storage_svc, fpath)


def register_replica(client, rse, scope, name, pfn, size, adler32):
    log.info(
        "  Registering %s:%s at %s (bytes=%d adler32=%s)",
        scope,
        name,
        rse,
        size,
        adler32,
    )
    try:
        client.add_replicas(
            rse=rse,
            files=[
                {
                    "scope": scope,
                    "name": name,
                    "bytes": size,
                    "adler32": adler32,
                    "pfn": pfn,
                }
            ],
        )
        log.info("  ✓ Replica registered at %s", rse)
    except Duplicate:
        log.warning("  Replica %s:%s already exists", scope, name)
    except RucioException as e:
        log.error("  Registration failed: %s", e)
        raise


def add_rule(client, scope, name, dst_rse):
    rule_ids = client.add_replication_rule(
        dids=[{"scope": scope, "name": name}],
        copies=1,
        rse_expression=dst_rse,
    )
    rule_id = rule_ids[0]
    log.info("  ✓ Rule created: %s -> %s (%s)", name, dst_rse, rule_id)
    return rule_id


def run_daemons(rucio_svc: str):
    log.info("=== Running daemons on %s ===", rucio_svc)
    for daemon in (
        ["rucio-judge-evaluator", "--run-once"],
        ["rucio-conveyor-submitter", "--run-once"],
        ["rucio-conveyor-poller", "--run-once", "--older-than", "0"],
        ["rucio-conveyor-finisher", "--run-once"],
    ):
        log.info("  → %s", " ".join(daemon))
        svc_exec(rucio_svc, daemon)


def validate_rule(client, rule_id, label, rucio_svc, timeout=180):
    """Poll until locks_ok >= 1 and locks_replicating == 0; advance daemons each loop."""
    log.info("=== Validating rule %s (%s) ===", rule_id, label)
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            rule = client.get_replication_rule(rule_id)
        except RuleNotFound:
            time.sleep(2)
            continue

        ok = rule["locks_ok_cnt"]
        repl = rule["locks_replicating_cnt"]
        stk = rule["locks_stuck_cnt"]
        log.info("  locks OK=%d REPL=%d STUCK=%d", ok, repl, stk)

        if stk > 0:
            raise RuntimeError(f"Rule {rule_id} has {stk} stuck locks")
        if ok >= 1 and repl == 0:
            log.info("  ✓ %s passed", label)
            return

        log.info("  (running daemon cycle to advance transfer)")
        svc_exec(
            rucio_svc, ["rucio-conveyor-poller", "--run-once", "--older-than", "0"]
        )
        svc_exec(rucio_svc, ["rucio-conveyor-finisher", "--run-once"])
        time.sleep(5)

    raise TimeoutError(f"Rule {rule_id} did not converge within {timeout}s")


def seed_and_register(client, rse, scope, name, storage_svc, owner):
    pfn = compute_pfn(client, rse, scope, name)
    local = pfn_to_local_path(rse, pfn)
    log.info("  PFN:            %s", pfn)
    log.info("  Container path: %s", local)

    seed_file(storage_svc, local, owner)
    size, adler32 = compute_metadata_from_storage(storage_svc, local)
    register_replica(client, rse, scope, name, pfn, size, adler32)


def transfer_workflow(
    client, src_rse, dst_rse, src_svc, dst_svc, scope, name, rucio_svc, owner, label
):
    log.info("[ Test: %s (%s -> %s) ]", label, src_rse, dst_rse)

    seed_and_register(client, src_rse, scope, name, src_svc, owner)

    dst_pfn = compute_pfn(client, dst_rse, scope, name)
    dst_path = pfn_to_local_path(dst_rse, dst_pfn)
    prepare_dest_dir(dst_svc, dst_path, owner)

    rule_id = add_rule(client, scope, name, dst_rse)
    run_daemons(rucio_svc)
    validate_rule(client, rule_id, label, rucio_svc)


# ── Tests ──────────────────────────────────────────────────────────────────
@pytest.mark.skipif(
    SHOULD_SKIP_GSI,
    reason=f"Skipping XRootD GSI test on {RUNTIME} runtime (SKIP_GSI={SKIP_GSI})",
)
def test_xrootd_gsi(client_std, fts_proxy):
    scope, name = "ddmlab", f"gsi-{int(time.time())}"
    transfer_workflow(
        client_std,
        src_rse="XRD1",
        dst_rse="XRD2",
        src_svc=XRD1,
        dst_svc=XRD2,
        scope=scope,
        name=name,
        rucio_svc=RUCIO,
        owner="xrootd",
        label="XRootD GSI",
    )


def test_storm_oidc(client_oidc):
    scope, name = "ddmlab", f"storm-{int(time.time())}"
    transfer_workflow(
        client_oidc,
        src_rse="STORM1",
        dst_rse="STORM2",
        src_svc=STORM1,
        dst_svc=STORM2,
        scope=scope,
        name=name,
        rucio_svc=RUCIO_OIDC,
        owner="storm",
        label="StoRM OIDC",
    )


def test_xrootd_oidc(client_oidc):
    scope, name = "ddmlab", f"xrd-oidc-{int(time.time())}"
    transfer_workflow(
        client_oidc,
        src_rse="XRD3",
        dst_rse="XRD4",
        src_svc=XRD3,
        dst_svc=XRD4,
        scope=scope,
        name=name,
        rucio_svc=RUCIO_OIDC,
        owner="xrootd",
        label="XRootD OIDC",
    )
