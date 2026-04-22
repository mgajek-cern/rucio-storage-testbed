#!/usr/bin/env python3
"""
Python equivalent of test-rucio-transfers.sh — runs the same three scenarios
(XRootD GSI, StoRM OIDC, XRootD OIDC) using the Rucio Python client.

Designed to run INSIDE the rucio-client container:
    docker exec compose-rucio-client-1 \\
      python3 /scripts/test-rucio-transfers.py
"""

import logging
import re
import subprocess
import sys
import time
import zlib
from typing import Tuple

from rucio.client import Client
from rucio.common.config import get_config
from rucio.common.exception import Duplicate, RucioException, RuleNotFound
from rucio.rse import rsemanager as rsemgr


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-7s %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("rucio-transfers")


# ── Topology ───────────────────────────────────────────────────────────────
CLIENT = "compose-rucio-client-1"
RUCIO = "compose-rucio-1"
RUCIO_OIDC = "compose-rucio-oidc-1"
XRD1 = "compose-xrd1-1"
XRD3 = "compose-xrd3-1"
XRD4 = "compose-xrd4-1"
STORM1 = "compose-storm1-1"
STORM2 = "compose-storm2-1"
FTS = "compose-fts-1"

CFG_STD = "/opt/rucio/etc/userpass-client.cfg"
CFG_OIDC = "/opt/rucio/etc/userpass-client-for-rucio-oidc.cfg"


def _client(cfg_path: str) -> Client:
    # Load the specific config file into a local object
    conf = get_config()
    conf.read(cfg_path)

    rucio_host = conf.get("client", "rucio_host")
    # Extract the connection info from the [client] section of your .cfg
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

    log.info("  Connected to Rucio at %s (VO: %s)", rucio_host, c.vo)
    return c


def docker_exec(
    container: str,
    cmd: list,
    user: str = None,
    stdin: bytes = None,
    capture: bool = True,
) -> bytes:
    full = ["docker", "exec"]
    if user:
        full += ["--user", user]
    if stdin is not None:
        full += ["-i"]
    full += [container] + cmd
    result = subprocess.run(full, input=stdin, capture_output=capture, check=True)
    return result.stdout if capture else b""


def compute_metadata_from_storage(storage_ctr: str, fpath: str) -> Tuple[int, str]:
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


def seed_file(storage_ctr: str, fpath: str, owner: str) -> None:
    script = (
        "set -e; "
        f'mkdir -p "$(dirname {fpath})"; '
        f'printf "rucio-test\\n" > {fpath}; '
        f"chown {owner}:{owner} {fpath}; "
        f"ls -la {fpath}"
    )
    out = docker_exec(storage_ctr, ["sh", "-c", script], user="root")
    log.info("  %s", out.decode().strip())


def register_replica(
    client: Client, rse: str, scope: str, name: str, pfn: str, size: int, adler32: str
) -> None:
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


def add_rule(client: Client, scope: str, name: str, dst_rse: str) -> str:
    rule_ids = client.add_replication_rule(
        dids=[{"scope": scope, "name": name}],
        copies=1,
        rse_expression=dst_rse,
    )
    rule_id = rule_ids[0]
    log.info("  ✓ Rule created: %s", rule_id)
    return rule_id


def run_daemons(rucio_ctr: str) -> None:
    log.info("=== Running daemons on %s ===", rucio_ctr)
    for daemon in (
        ["rucio-judge-evaluator", "--run-once"],
        ["rucio-conveyor-submitter", "--run-once"],
        ["rucio-conveyor-poller", "--run-once", "--older-than", "0"],
        ["rucio-conveyor-finisher", "--run-once"],
    ):
        docker_exec(rucio_ctr, daemon, capture=False)


def validate_rule(
    client: Client, rule_id: str, label: str, rucio_ctr: str, timeout: int = 180
) -> None:
    """Poll the rule until locks_ok >= 1 and locks_replicating == 0.
    Each loop iteration advances the daemon cycle so transfers progress."""
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
            rucio_ctr,
            ["rucio-conveyor-poller", "--run-once", "--older-than", "0"],
            capture=False,
        )
        docker_exec(rucio_ctr, ["rucio-conveyor-finisher", "--run-once"], capture=False)
        time.sleep(5)

    raise TimeoutError(f"Rule {rule_id} did not converge within {timeout}s")


def delegate_proxy() -> None:
    log.info("=== Delegating proxy to FTS ===")
    py = (
        "import datetime, fts3.rest.client.easy as fts3\n"
        "ctx = fts3.Context('https://fts:8446', "
        "ucert='/etc/grid-security/hostcert.pem', "
        "ukey='/etc/grid-security/hostkey.pem', verify=False)\n"
        "fts3.delegate(ctx, lifetime=datetime.timedelta(hours=48), force=True)\n"
        "print('  Delegation OK - DN:', fts3.whoami(ctx)['user_dn'])"
    )
    docker_exec(FTS, ["python3", "-c", py], capture=False)


def seed_and_register(
    client: Client, rse: str, scope: str, name: str, storage_ctr: str, owner: str
) -> None:
    pfn = compute_pfn(client, rse, scope, name)
    local_fpath = pfn_to_local_path(rse, pfn)
    log.info("  PFN:            %s", pfn)
    log.info("  Container path: %s", local_fpath)

    seed_file(storage_ctr, local_fpath, owner)
    size, adler32 = compute_metadata_from_storage(storage_ctr, local_fpath)
    register_replica(client, rse, scope, name, pfn, size, adler32)


def test_xrootd_gsi() -> None:
    log.info("\n[ Test: XRootD GSI (XRD1 -> XRD2) ]")
    delegate_proxy()
    client = _client(CFG_STD)
    scope, name = "ddmlab", f"gsi-{int(time.time())}"
    seed_and_register(client, "XRD1", scope, name, XRD1, "xrootd")
    rule_id = add_rule(client, scope, name, "XRD2")
    run_daemons(RUCIO)
    validate_rule(client, rule_id, "XRootD GSI", RUCIO)


def test_storm_oidc() -> None:
    log.info("\n[ Test: StoRM OIDC (STORM1 -> STORM2) ]")
    client = _client(CFG_OIDC)
    scope, name = "ddmlab", f"storm-{int(time.time())}"

    dest_pfn = compute_pfn(client, "STORM2", scope, name)
    dest_fpath = pfn_to_local_path("STORM2", dest_pfn)
    docker_exec(
        STORM2,
        [
            "sh",
            "-c",
            f"mkdir -p $(dirname {dest_fpath}) && "
            f"chown -R storm:storm /storage/data/{scope}",
        ],
        user="root",
    )

    seed_and_register(client, "STORM1", scope, name, STORM1, "storm")
    rule_id = add_rule(client, scope, name, "STORM2")
    run_daemons(RUCIO_OIDC)
    validate_rule(client, rule_id, "StoRM OIDC", RUCIO_OIDC)


def test_xrootd_oidc() -> None:
    log.info("\n[ Test: XRootD OIDC (XRD3 -> XRD4) ]")
    client = _client(CFG_OIDC)
    scope, name = "ddmlab", f"xrd-oidc-{int(time.time())}"

    dest_pfn = compute_pfn(client, "XRD4", scope, name)
    dest_fpath = pfn_to_local_path("XRD4", dest_pfn)
    docker_exec(
        XRD4,
        [
            "sh",
            "-c",
            f"mkdir -p $(dirname {dest_fpath}) && "
            f"chown xrootd:xrootd $(dirname {dest_fpath})",
        ],
        user="root",
    )

    seed_and_register(client, "XRD3", scope, name, XRD3, "xrootd")
    rule_id = add_rule(client, scope, name, "XRD4")
    run_daemons(RUCIO_OIDC)
    validate_rule(client, rule_id, "XRootD OIDC", RUCIO_OIDC)


def main() -> int:
    tests = [
        ("XRootD GSI", test_xrootd_gsi),
        ("StoRM OIDC", test_storm_oidc),
        ("XRootD OIDC", test_xrootd_oidc),
    ]
    failures = []
    for name, fn in tests:
        try:
            fn()
        except Exception as e:
            log.error("✗ %s failed: %s", name, e)
            failures.append(name)

    if failures:
        log.error("\nFAILED: %s", ", ".join(failures))
        return 1
    log.info("\nAll tests passed ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
