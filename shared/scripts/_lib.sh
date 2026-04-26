#!/usr/bin/env bash
# Sourced by bootstrap-testbed.sh and test-*.sh.
# Provides cross-runtime helpers: _exec, _exec_root, _restart,
# _http_probe_local, _fts_url, _fts_curl, _fetch_token, _adler32,
# _cp_to, _cp_from.

RUNTIME="${RUNTIME:-compose}"
K8S_NAMESPACE="${K8S_NAMESPACE:-rucio-testbed}"

# Compose file used for `docker compose ...` calls. Override via env.
COMPOSE_FILE="${COMPOSE_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/deploy/compose/docker-compose.yml}"

# _exec <service> -- <command…>
#
# In compose mode: docker exec compose-<service>-1 <command…>
# In k8s mode:     kubectl exec deploy/<service> [-c <svc>] -- <command…>
#
# StatefulSet pods are addressed as pod/<name>-0 with no -c flag (single
# container, name varies by chart). Sidecar Deployments (rucio, rucio-oidc)
# need -c to pick the app container, not the log-tailer sidecar.
_exec() {
    local svc=$1; shift
    case "$RUNTIME" in
        compose)
            docker exec "compose-${svc}-1" "$@"
            ;;
        k8s)
            local target
            local -a cflag=()
            case "$svc" in
                ftsdb|ftsdb-oidc|ruciodb|ruciodb-oidc|storm1|storm2|minio1|minio2)
                    target="pod/${svc}-0" ;;
                rucio|rucio-oidc)
                    target="deploy/${svc}"; cflag=(-c "$svc") ;;
                *)
                    target="deploy/${svc}" ;;
            esac
            kubectl -n "$K8S_NAMESPACE" exec "$target" "${cflag[@]}" -- "$@"
            ;;
        *) echo "Unknown RUNTIME: $RUNTIME" >&2; return 2 ;;
    esac
}

# Run --user root inside a service container.
# In k8s, most images already run as root; if not, the chart needs
# securityContext.runAsUser: 0.
_exec_root() {
    local svc=$1; shift
    case "$RUNTIME" in
        compose) docker exec --user root "compose-${svc}-1" "$@" ;;
        k8s)     _exec "$svc" "$@" ;;
    esac
}

# Graceful restart of one or more services.
_restart() {
    case "$RUNTIME" in
        compose)
            docker compose -f "$COMPOSE_FILE" restart "$@" ;;
        k8s)
            for svc in "$@"; do
                local target
                case "$svc" in
                    storm1|storm2|minio1|minio2|ftsdb*|ruciodb*)
                        target="statefulset/${svc}" ;;
                    *)
                        target="deploy/${svc}" ;;
                esac
                kubectl -n "$K8S_NAMESPACE" rollout restart "$target"
                kubectl -n "$K8S_NAMESPACE" rollout status  "$target" --timeout=120s
            done ;;
    esac
}

# Probe an HTTP endpoint as seen "from the outside".
# Compose: hits the host's localhost (relies on published ports).
# K8s:     execs into rucio-oidc and curls localhost there.
# Returns the HTTP status code (or "000" on connection failure).
_http_probe_local() {
    local port=$1 path=$2
    case "$RUNTIME" in
        compose)
            curl -s -o /dev/null -w '%{http_code}' \
                "http://localhost:${port}${path}" || true ;;
        k8s)
            _exec rucio-oidc curl -s -o /dev/null -w '%{http_code}' \
                "http://localhost${path}" 2>/dev/null || true ;;
    esac
}

# FTS REST endpoint as seen from the test runner.
# Compose: published port. K8s: in-cluster Service (run curl from a pod).
_fts_url() {
    local variant=${1:-oidc}   # gsi | oidc
    case "$RUNTIME:$variant" in
        compose:gsi)  echo "https://localhost:8446" ;;
        compose:oidc) echo "https://localhost:8447" ;;
        k8s:gsi)      echo "https://fts:8446" ;;
        k8s:oidc)     echo "https://fts-oidc:8446" ;;
    esac
}

# Run a curl that hits FTS, automatically choosing where to run from.
# Compose runs from the host (cacert path needs to be host-side).
# K8s runs from inside fts-<variant> (cacert is on the pod's filesystem).
_fts_curl() {
    local variant=$1; shift
    case "$RUNTIME" in
        compose)
            curl -sk --cacert "${CACERT:-./certs/rucio_ca.pem}" "$@" ;;
        k8s)
            _exec "fts-${variant}" curl -sk "$@" ;;
    esac
}

# Get a token from Keycloak. Always runs inside fts-oidc since that container
# can reach https://keycloak:8443 directly with the right trust anchors.
_fetch_token() {
    local body=$1
    _exec fts-oidc curl -sk \
        -u "rucio-oidc:rucio-oidc-secret" \
        -d "$body" \
        https://keycloak:8443/realms/rucio/protocol/openid-connect/token \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}

# Compute adler32 of a file living inside src_svc, using python3 in dst_svc.
# The storm-webdav image is minimal and has no python3, so we always run
# the checksum in a Rucio container. The file streams via the test runner
# in k8s mode (no clean cross-pod pipe primitive).
_adler32() {
    local src_svc=$1 src_path=$2 dst_svc=$3
    case "$RUNTIME" in
        compose)
            docker exec "compose-${src_svc}-1" cat "$src_path" \
                | docker exec -i "compose-${dst_svc}-1" python3 -c '
import sys, zlib
print("%08x" % (zlib.adler32(sys.stdin.buffer.read()) & 0xffffffff))
' ;;
        k8s)
            local target_src target_dst
            case "$src_svc" in
                storm1|storm2) target_src="pod/${src_svc}-0" ;;
                *)             target_src="deploy/${src_svc}" ;;
            esac
            case "$dst_svc" in
                rucio|rucio-oidc) target_dst="deploy/${dst_svc}"; local cflag=(-c "$dst_svc") ;;
                *)                target_dst="deploy/${dst_svc}"; local cflag=() ;;
            esac
            kubectl -n "$K8S_NAMESPACE" exec "$target_src" -- cat "$src_path" \
                | kubectl -n "$K8S_NAMESPACE" exec -i "$target_dst" "${cflag[@]}" -- python3 -c '
import sys, zlib
print("%08x" % (zlib.adler32(sys.stdin.buffer.read()) & 0xffffffff))
' ;;
    esac
}

# Copy a host file into a service container.
_cp_to() {
    local src=$1 svc=$2 dst=$3
    case "$RUNTIME" in
        compose) docker cp "$src" "compose-${svc}-1:$dst" ;;
        k8s)     kubectl -n "$K8S_NAMESPACE" cp "$src" "deploy/${svc}:$dst" ;;
    esac
}

# Copy a file from a service container back to the host.
_cp_from() {
    local svc=$1 src=$2 dst=$3
    case "$RUNTIME" in
        compose) docker cp "compose-${svc}-1:$src" "$dst" ;;
        k8s)     kubectl -n "$K8S_NAMESPACE" cp "deploy/${svc}:$src" "$dst" ;;
    esac
}
