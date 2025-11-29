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

check_root() {
    [[ $EUID -ne 0 ]] && log_error "Run as root: sudo $0"
}

check_requirements() {
    log_info "Checking hardware requirements..."
    
    local cpu_cores=$(nproc)
    local ram_gb=$(free -g | awk '/^Mem:/{print $2}')
    local disk_gb=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    
    log_info "Detected: ${cpu_cores} vCPUs, ${ram_gb}GB RAM, ${disk_gb}GB free disk"
    
    [[ $cpu_cores -lt 16 ]] && log_error "Need 16+ vCPUs (have $cpu_cores)"
    [[ $ram_gb -lt 60 ]] && log_error "Need 64GB+ RAM (have ${ram_gb}GB)"
    [[ $disk_gb -lt 450 ]] && log_error "Need 500GB+ free disk (have ${disk_gb}GB)"
    
    log_info "Hardware requirements met"
}

install_docker() {
    if command -v docker &> /dev/null; then
        log_info "Docker already installed"
        return
    fi
    
    log_info "Installing Docker..."
    
    apt-get update -qq
    apt-get install -y ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    systemctl enable --now docker
    log_info "Docker installed"
}

configure_system() {
    log_info "Configuring system..."
    
    log_info "Disabling IPv6 (hl-node requirement)"
    cat > /etc/sysctl.d/99-hyperliquid.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
fs.file-max = 2097152
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
EOF
    sysctl -p /etc/sysctl.d/99-hyperliquid.conf > /dev/null
    
    log_info "Setting ulimits"
    cat > /etc/security/limits.d/hyperliquid.conf <<EOF
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
EOF
    
    log_info "Configuring firewall"
    if command -v ufw &> /dev/null; then
        ufw allow 4000:4010/tcp comment 'Hyperliquid P2P' > /dev/null 2>&1 || true
        
        if [[ "$RPC_EXTERNAL" == "true" ]]; then
            log_warn "Opening RPC port 3001 to external connections"
            ufw allow 3001/tcp comment 'Hyperliquid RPC' > /dev/null 2>&1 || true
        fi
    else
        log_warn "ufw not found, configure firewall manually:"
        log_warn "  - Allow ports 4000-4010/tcp (P2P)"
        [[ "$RPC_EXTERNAL" == "true" ]] && log_warn "  - Allow port 3001/tcp (RPC)"
    fi
}

create_compose() {
    log_info "Creating docker-compose configuration..."
    
    mkdir -p "$DATA_DIR"
    
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
    
    systemctl daemon-reload
    systemctl enable hyperliquid-node.service
}

start_node() {
    log_info "Starting Hyperliquid node..."
    
    cd "$DATA_DIR"
    docker compose pull
    systemctl start hyperliquid-node.service
    
    log_info "Waiting for node to initialize..."
    sleep 10
    
    for i in {1..30}; do
        if docker compose logs node 2>&1 | grep -q "applied block" || \
           docker compose logs node 2>&1 | grep -q "starting metrics server"; then
            log_info "Node is syncing!"
            break
        fi
        [[ $i -eq 30 ]] && log_warn "Node might be slow to start, check logs"
        sleep 2
    done
}

show_info() {
    local ip=$(curl -s4 ifconfig.me || echo "UNKNOWN")
    
    cat <<EOF

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
        cat <<EOF
  
  ${RED}External RPC:${NC} http://$ip:3001/evm
  ${RED}External Info:${NC} http://$ip:3001/info
  ${YELLOW}WARNING: RPC exposed publicly! Use firewall/VPN for security${NC}
EOF
    fi

    cat <<EOF

${GREEN}Management Commands:${NC}
  Status:       systemctl status hyperliquid-node
  Logs:         docker compose -f $DATA_DIR/docker-compose.yml logs -f
  Stop:         systemctl stop hyperliquid-node
  Start:        systemctl start hyperliquid-node
  Restart:      systemctl restart hyperliquid-node

${GREEN}Data Access:${NC}
  Trades:       $DATA_DIR/node-data/_data/hl/data/node_trades/
  Fills:        $DATA_DIR/node-data/_data/hl/data/node_fills/
  Order Status: $DATA_DIR/node-data/_data/hl/data/node_order_statuses/
  Raw Diffs:    $DATA_DIR/node-data/_data/hl/data/node_raw_book_diffs/

${YELLOW}Test Connection:${NC}
  curl -X POST http://127.0.0.1:3001/info \\
    -H "Content-Type: application/json" \\
    -d '{"type":"exchangeStatus"}'

${YELLOW}Next Steps:${NC}
  1. Monitor sync: docker compose -f $DATA_DIR/docker-compose.yml logs -f node
  2. Check metrics: curl http://127.0.0.1:2112/metrics
  3. Initial sync may take several hours
  
${GREEN}Done!${NC}
EOF
}

main() {
    log_info "Hyperliquid Node Installer for Mainnet"
    
    check_root
    check_requirements
    install_docker
    configure_system
    create_compose
    create_systemd
    start_node
    show_info
}

main "$@"
