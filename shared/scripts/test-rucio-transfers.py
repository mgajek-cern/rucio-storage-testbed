#!/usr/bin/env python3
"""
Python equivalent of test-rucio-transfers.sh — runs the same three scenarios
(XRootD GSI, StoRM OIDC, XRootD OIDC) using the Rucio Python client.

Typical invocations:
    docker exec compose-rucio-client-1 \\
        bash -c "pytest -v /scripts/test-rucio-transfers.py"

    kubectl -n rucio-testbed exec deploy/rucio-client -- \\
        bash -c "pytest -v /scripts/test-rucio-transfers.py"
"""

import logging
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


# ── Topology ───────────────────────────────────────────────────────────────
RUCIO = "compose-rucio-1"
RUCIO_OIDC = "compose-rucio-oidc-1"
XRD1 = "compose-xrd1-1"
XRD2 = "compose-xrd2-1"
XRD3 = "compose-xrd3-1"
XRD4 = "compose-xrd4-1"
STORM1 = "compose-storm1-1"
STORM2 = "compose-storm2-1"
FTS = "compose-fts-1"

CFG_STD = "/opt/rucio/etc/userpass-client.cfg"
CFG_OIDC = "/opt/rucio/etc/userpass-client-for-rucio-oidc.cfg"


# ── Client factory ─────────────────────────────────────────────────────────
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
    log.info("Connected to Rucio at %s (VO: %s)", rucio_host, c.vo)
    return c


# ── Fixtures ───────────────────────────────────────────────────────────────
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
    out = docker_exec(FTS, ["python3", "-c", py])
    log.info("  %s", out.decode().strip())


# ── Docker helper ───────────────────────────────────────────────────────────
def docker_exec(container: str, cmd: list, user: str = None) -> bytes:
    full = ["docker", "exec"]
    if user:
        full += ["--user", user]
    full += [container] + cmd
    result = subprocess.run(full, capture_output=True, check=True)
    return result.stdout


# ── Storage helpers ─────────────────────────────────────────────────────────
def compute_metadata_from_storage(storage_ctr: str, fpath: str):
    raw = docker_exec(storage_ctr, ["cat", fpath])
    size = len(raw)
    if size == 0:
        raise RuntimeError(f"File {fpath} on {storage_ctr} is empty or missing")
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


def seed_file(storage_ctr: str, fpath: str, owner: str):
    script = (
        "set -e; "
        f'mkdir -p "$(dirname {fpath})"; '
        f'printf "rucio-test\\n" > {fpath}; '
        f"chown {owner}:{owner} {fpath}; "
        f"ls -la {fpath}"
    )
    out = docker_exec(storage_ctr, ["sh", "-c", script], user="root")
    log.info("  %s", out.decode().strip())


def prepare_dest_dir(storage_ctr: str, fpath: str, owner: str):
    script = (
        f'mkdir -p "$(dirname {fpath})" && chown {owner}:{owner} "$(dirname {fpath})"'
    )
    docker_exec(storage_ctr, ["sh", "-c", script], user="root")
    log.info("  ✓ Destination dir ready on %s: %s", storage_ctr, fpath)


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


def run_daemons(rucio_ctr: str):
    log.info("=== Running daemons on %s ===", rucio_ctr)
    for daemon in (
        ["rucio-judge-evaluator", "--run-once"],
        ["rucio-conveyor-submitter", "--run-once"],
        ["rucio-conveyor-poller", "--run-once", "--older-than", "0"],
        ["rucio-conveyor-finisher", "--run-once"],
    ):
        log.info("  → %s", " ".join(daemon))
        docker_exec(rucio_ctr, daemon)


def validate_rule(client, rule_id, label, rucio_ctr, timeout=180):
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
        docker_exec(
            rucio_ctr, ["rucio-conveyor-poller", "--run-once", "--older-than", "0"]
        )
        docker_exec(rucio_ctr, ["rucio-conveyor-finisher", "--run-once"])
        time.sleep(5)

    raise TimeoutError(f"Rule {rule_id} did not converge within {timeout}s")


def seed_and_register(client, rse, scope, name, storage_ctr, owner):
    pfn = compute_pfn(client, rse, scope, name)
    local = pfn_to_local_path(rse, pfn)
    log.info("  PFN:            %s", pfn)
    log.info("  Container path: %s", local)

    seed_file(storage_ctr, local, owner)
    size, adler32 = compute_metadata_from_storage(storage_ctr, local)
    register_replica(client, rse, scope, name, pfn, size, adler32)


def transfer_workflow(
    client, src_rse, dst_rse, src_ctr, dst_ctr, scope, name, rucio_ctr, owner, label
):
    log.info("[ Test: %s (%s -> %s) ]", label, src_rse, dst_rse)

    seed_and_register(client, src_rse, scope, name, src_ctr, owner)

    dst_pfn = compute_pfn(client, dst_rse, scope, name)
    dst_path = pfn_to_local_path(dst_rse, dst_pfn)
    prepare_dest_dir(dst_ctr, dst_path, owner)

    rule_id = add_rule(client, scope, name, dst_rse)
    run_daemons(rucio_ctr)
    validate_rule(client, rule_id, label, rucio_ctr)


# ── Tests ──────────────────────────────────────────────────────────────────
def test_xrootd_gsi(client_std, fts_proxy):
    scope, name = "ddmlab", f"gsi-{int(time.time())}"
    transfer_workflow(
        client_std,
        src_rse="XRD1",
        dst_rse="XRD2",
        src_ctr=XRD1,
        dst_ctr=XRD2,
        scope=scope,
        name=name,
        rucio_ctr=RUCIO,
        owner="xrootd",
        label="XRootD GSI",
    )


def test_storm_oidc(client_oidc):
    scope, name = "ddmlab", f"storm-{int(time.time())}"
    transfer_workflow(
        client_oidc,
        src_rse="STORM1",
        dst_rse="STORM2",
        src_ctr=STORM1,
        dst_ctr=STORM2,
        scope=scope,
        name=name,
        rucio_ctr=RUCIO_OIDC,
        owner="storm",
        label="StoRM OIDC",
    )


def test_xrootd_oidc(client_oidc):
    scope, name = "ddmlab", f"xrd-oidc-{int(time.time())}"
    transfer_workflow(
        client_oidc,
        src_rse="XRD3",
        dst_rse="XRD4",
        src_ctr=XRD3,
        dst_ctr=XRD4,
        scope=scope,
        name=name,
        rucio_ctr=RUCIO_OIDC,
        owner="xrootd",
        label="XRootD OIDC",
    )
