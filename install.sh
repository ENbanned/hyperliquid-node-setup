#!/usr/bin/env bash
set -euo pipefail

NETWORK="mainnet"
IMAGE="ghcr.io/buckshotcapital/hyperliquid-node:mainnet"
DATA_DIR="/opt/hyperliquid"
RPC_EXTERNAL=${RPC_EXTERNAL:-false}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

trap 'log_error "Script failed at line $LINENO"' ERR

check_root() {
    log_info "Checking root privileges..."
    if [[ $EUID -ne 0 ]]; then
        log_error "Run as root: sudo $0"
    fi
}

check_requirements() {
    log_info "Checking hardware requirements..."
    
    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || echo "0")
    log_info "CPU cores: $cpu_cores"
    
    local ram_gb
    ram_gb=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0")
    log_info "RAM: ${ram_gb}GB"
    
    local disk_gb
    disk_gb=$(df -BG / 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/G//' || echo "0")
    log_info "Free disk: ${disk_gb}GB"
    
    local errors=0
    
    if [[ $cpu_cores -lt 16 ]]; then
        log_warn "CPU: Need 16+ vCPUs, have $cpu_cores (may work but slow)"
        ((errors++))
    fi
    
    if [[ $ram_gb -lt 60 ]]; then
        log_warn "RAM: Need 64GB+, have ${ram_gb}GB (may cause OOM)"
        ((errors++))
    fi
    
    if [[ $disk_gb -lt 450 ]]; then
        log_warn "Disk: Need 500GB+ free, have ${disk_gb}GB (will fill up fast)"
        ((errors++))
    fi
    
    if [[ $errors -gt 0 ]]; then
        log_warn "Hardware below recommended specs"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && log_error "Installation cancelled"
    else
        log_info "Hardware requirements met"
    fi
}

install_docker() {
    if command -v docker &> /dev/null; then
        log_info "Docker already installed: $(docker --version)"
        return
    fi
    
    log_info "Installing Docker..."
    
    apt-get update -qq || log_error "apt-get update failed"
    apt-get install -y ca-certificates curl gnupg || log_error "Failed to install prerequisites"
    
    install -m 0755 -d /etc/apt/keyrings
    
    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc || log_error "Failed to download Docker GPG key"
        chmod a+r /etc/apt/keyrings/docker.asc
    fi
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    
    apt-get update -qq || log_error "Failed to update apt with Docker repo"
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || log_error "Failed to install Docker"
    
    systemctl enable --now docker || log_error "Failed to start Docker"
    
    docker --version || log_error "Docker installed but not working"
    log_info "Docker installed successfully"
}

configure_system() {
    log_info "Configuring system..."
    
    log_info "Disabling IPv6..."
    cat > /etc/sysctl.d/99-hyperliquid.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
fs.file-max = 2097152
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
EOF
    sysctl -p /etc/sysctl.d/99-hyperliquid.conf > /dev/null || log_warn "Failed to apply sysctl settings"
    
    log_info "Setting ulimits..."
    cat > /etc/security/limits.d/hyperliquid.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
EOF
    
    log_info "Configuring firewall..."
    if ! command -v ufw &> /dev/null; then
        log_warn "UFW not installed, installing..."
        apt-get install -y ufw || log_warn "Failed to install UFW"
    fi

    if command -v ufw &> /dev/null; then
        if ! ufw status | grep -q "Status: active"; then
            log_info "Enabling UFW..."
            ufw --force enable || log_warn "Failed to enable UFW"
        fi
        
        log_info "Opening required ports..."
        ufw allow ssh comment 'SSH' > /dev/null 2>&1 || true
        ufw allow 4000:4010/tcp comment 'Hyperliquid P2P' || log_warn "Failed to add P2P firewall rule"
        
        if [[ "$RPC_EXTERNAL" == "true" ]]; then
            log_warn "Opening RPC port 3001 to external connections"
            ufw allow 3001/tcp comment 'Hyperliquid RPC' || log_warn "Failed to add RPC firewall rule"
        fi
        
        ufw status numbered
    else
        log_warn "Configure firewall manually: allow ports 4000-4010/tcp"
    fi
}

create_compose() {
    log_info "Creating Docker Compose configuration..."
    
    mkdir -p "$DATA_DIR" || log_error "Failed to create data directory"
    
    local rpc_ports="127.0.0.1:3001:3001"
    [[ "$RPC_EXTERNAL" == "true" ]] && rpc_ports="0.0.0.0:3001:3001"
    
    cat > "$DATA_DIR/docker-compose.yml" <<EOF
name: hyperliquid

services:
  node:
    image: $IMAGE
    container_name: hyperliquid-node
    restart: unless-stopped
    command:
      - run-non-validator
      - --write-trades
      - --write-fills
      - --write-order-statuses
      - --write-raw-book-diffs
      - --write-hip3-oracle-updates
      - --write-misc-events
      - --write-system-and-core-writer-actions
      - --serve-eth-rpc
      - --serve-info
      - --disable-output-file-buffering
    read_only: true
    sysctls:
      net.ipv6.conf.all.disable_ipv6: "1"
    environment:
      RUST_LOG: "info,hl_bootstrap=debug"
      HL_BOOTSTRAP_METRICS_LISTEN_ADDRESS: "0.0.0.0:2112"
      HL_BOOTSTRAP_PRUNE_DATA_INTERVAL: "1h"
      HL_BOOTSTRAP_PRUNE_DATA_OLDER_THAN: "4h"
      HL_BOOTSTRAP_SEED_PEERS_MAX_LATENCY: "80ms"
    volumes:
      - node-data:/data
      - node-bin:/opt/hl/bin
    ports:
      - "$rpc_ports"
      - "127.0.0.1:2112:2112"
      - "0.0.0.0:4000-4010:4000-4010"
    deploy:
      resources:
        limits:
          cpus: "16"
          memory: 64G
          pids: 1024
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576

volumes:
  node-data:
    driver: local
  node-bin:
    driver: local
EOF
    
    log_info "Compose file created at $DATA_DIR/docker-compose.yml"
}

create_systemd() {
    log_info "Creating systemd service..."
    
    cat > /etc/systemd/system/hyperliquid-node.service <<EOF
[Unit]
Description=Hyperliquid Node
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$DATA_DIR
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload || log_error "Failed to reload systemd"
    systemctl enable hyperliquid-node.service || log_error "Failed to enable service"
    log_info "Systemd service created and enabled"
}

start_node() {
    log_info "Pulling Docker image (this may take a while)..."
    
    cd "$DATA_DIR" || log_error "Failed to cd to $DATA_DIR"
    docker compose pull || log_error "Failed to pull Docker image"
    
    log_info "Starting Hyperliquid node..."
    systemctl start hyperliquid-node.service || log_error "Failed to start service"
    
    log_info "Waiting for node to initialize..."
    sleep 10
    
    for i in {1..30}; do
        if docker compose logs node 2>&1 | grep -q "applied block\|starting metrics server\|testing latency"; then
            log_info "Node is starting up!"
            break
        fi
        if [[ $i -eq 30 ]]; then
            log_warn "Node startup taking longer than expected"
            log_info "Check logs: docker compose -f $DATA_DIR/docker-compose.yml logs -f node"
        fi
        sleep 2
    done
}

show_info() {
    local ip
    ip=$(curl -s4 --max-time 5 ifconfig.me || echo "UNKNOWN")
    
    echo -e

${GREEN}╔════════════════════════════════════════════════════════════╗
║           Hyperliquid Node Installation Complete          ║
╚════════════════════════════════════════════════════════════╝${NC}

${YELLOW}Network:${NC} Mainnet
${YELLOW}Data Directory:${NC} $DATA_DIR
${YELLOW}Public IP:${NC} $ip

${GREEN}RPC Endpoints:${NC}
  EVM RPC:  http://127.0.0.1:3001/evm
  Info API: http://127.0.0.1:3001/info
  Metrics:  http://127.0.0.1:2112/metrics
EOF

    if [[ "$RPC_EXTERNAL" == "true" ]]; then
        echo -e
  
  ${RED}External RPC:${NC} http://$ip:3001/evm
  ${RED}External Info:${NC} http://$ip:3001/info
  ${YELLOW}WARNING: RPC exposed publicly! Use firewall/VPN${NC}
EOF
    fi

    echo -e

${GREEN}Management Commands:${NC}
  Status:  systemctl status hyperliquid-node
  Logs:    docker compose -f $DATA_DIR/docker-compose.yml logs -f node
  Stop:    systemctl stop hyperliquid-node
  Start:   systemctl start hyperliquid-node
  Restart: systemctl restart hyperliquid-node

${GREEN}Test Connection:${NC}
  curl -X POST http://127.0.0.1:3001/info \\
    -H "Content-Type: application/json" \\
    -d '{"type":"exchangeStatus"}'

${YELLOW}Initial sync may take several hours${NC}
Monitor: docker compose -f $DATA_DIR/docker-compose.yml logs -f node

${GREEN}Installation log saved to: install.log${NC}
EOF
}

main() {
    log_info "Hyperliquid Node Installer for Mainnet"
    echo
    
    check_root
    check_requirements
    install_docker
    configure_system
    create_compose
    create_systemd
    start_node
    show_info
}

main "$@" 2>&1 | tee /root/hyperliquid-install.log
