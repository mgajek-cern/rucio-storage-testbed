#!/bin/bash
set -e

# Color definitions
BLUE='\033[0;34m'; RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

# --- Helper Functions ---

check_requirements() {
    echo -e "${CYAN}📋 System Requirements Check...${NC}"
    echo -e "${YELLOW} • Disk: 20-30+ GB | Memory: 8-16+ GB | Docker: Running${NC}"

    if [ $(uname -m) = x86_64 ]; then ARCH="amd64"; elif [ $(uname -m) = aarch64 ]; then ARCH="arm64"; else
        echo -e "${RED}Unsupported architecture: $(uname -m)${NC}"; exit 1
    fi
    echo -e "${BLUE}Detected architecture: $ARCH${NC}"

    echo -e "${BLUE}Waiting for Docker daemon...${NC}"
    timeout 30 bash -c 'until docker info > /dev/null 2>&1; do sleep 1; done' || {
        echo -e "${RED}Docker daemon failed to start${NC}"; exit 1
    }
    echo -e "${GREEN}Docker is ready${NC}\n"
}

install_kind() {
    local KIND_RELEASE="v0.29.0"
    echo -e "${BLUE}Installing Kind $KIND_RELEASE...${NC}"
    curl -Lo ./kind "https://kind.sigs.k8s.io/dl/$KIND_RELEASE/kind-linux-${ARCH}"
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind

    kind delete cluster --name kind || true
    echo -e "${BLUE}Creating kind cluster...${NC}"
    kind create cluster --name kind --wait=180s
    kind get kubeconfig --name kind --internal=false > ~/.kube/config

    if ! kubectl get nodes > /dev/null 2>&1; then
        echo -e "${RED}Cluster failed to start${NC}"; docker logs kind-control-plane; exit 1
    fi
    echo -e "${GREEN}Kind cluster ready${NC}\n"
}

install_chart_testing() {
    local CT_VERSION="v3.13.0"
    echo -e "${BLUE}Installing chart-testing $CT_VERSION...${NC}"

    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    curl -sSL -o "$tmp/ct.tar.gz" \
        "https://github.com/helm/chart-testing/releases/download/$CT_VERSION/chart-testing_${CT_VERSION#v}_linux_${ARCH}.tar.gz"

    # Extract into the tmp dir — the tarball ships with a top-level
    # README.md, LICENSE, and etc/ that would clobber the repo's own
    # files if extracted into the current directory.
    tar -xzf "$tmp/ct.tar.gz" -C "$tmp"

    sudo install -m 0755 "$tmp/ct" /usr/local/bin/ct

    echo -e "${BLUE}Installing Python dependencies...${NC}"
    pip install yamllint==1.37.1

    echo -e "${GREEN}Chart-testing installed${NC}\n"
}

generate_configs() {
    echo -e "${BLUE}Generating configuration files...${NC}"
    cat > ct.yaml << EOF
chart-dirs:
  - charts
validate-maintainers: false
check-version-increment: false
validate-chart-schema: false
EOF
    cat > lintconf.yaml << EOF
---
rules:
  line-length: disable
EOF
    echo -e "${GREEN}✓ ct.yaml and lintconf.yaml created${NC}\n"
}

print_summary() {
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                    Sample Commands                           ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${CYAN}ct lint --all${NC} or ${CYAN}helm lint charts/rucio-server/${NC}"
    echo -e "${GREEN}Setup complete!${NC}"
}

# --- Execution ---

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                 Kind Cluster Setup Script                   ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}\n"

check_requirements
install_kind
install_chart_testing
generate_configs
print_summary
