#!/bin/bash

# Proxmox LXC Container Setup for Zepplin Registry
# Supports Debian 12 and Ubuntu 24.04 LTS with Docker + Docker Compose
# Usage: ./setup-lxc.sh [debian|ubuntu] <container_id> <container_name>

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_step() {
    echo -e "${GREEN}[STEP]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Print banner
echo -e "${BLUE}"
echo "🚀 Zepplin Registry - Proxmox LXC Setup"
echo "======================================="
echo -e "${NC}"

# Parse arguments
OS_TYPE=${1:-debian}
CONTAINER_ID=${2:-100}
CONTAINER_NAME=${3:-zepplin-registry}

if [[ ! "$OS_TYPE" =~ ^(debian|ubuntu)$ ]]; then
    print_error "Invalid OS type. Use 'debian' or 'ubuntu'"
    exit 1
fi

# Container configuration
if [ "$OS_TYPE" = "debian" ]; then
    TEMPLATE="local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst"
    OS_VERSION="Debian 12"
else
    TEMPLATE="local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
    OS_VERSION="Ubuntu 24.04 LTS"
fi

ROOTFS_SIZE="20G"
MEMORY="2048"
CORES="2"
NETWORK="name=eth0,bridge=vmbr0,firewall=1,ip=dhcp"

print_info "Creating LXC container for Zepplin Registry"
print_info "OS: $OS_VERSION"
print_info "Container ID: $CONTAINER_ID"
print_info "Container Name: $CONTAINER_NAME"
print_info "Resources: ${CORES} cores, ${MEMORY}MB RAM, ${ROOTFS_SIZE} storage"

# Create the container
print_step "Creating LXC container..."
pct create $CONTAINER_ID $TEMPLATE \
    --hostname $CONTAINER_NAME \
    --memory $MEMORY \
    --cores $CORES \
    --rootfs local-lvm:$ROOTFS_SIZE \
    --net0 $NETWORK \
    --features nesting=1,keyctl=1 \
    --unprivileged 1 \
    --onboot 1 \
    --startup order=3,up=30

print_step "Starting container..."
pct start $CONTAINER_ID

# Wait for container to be ready
print_step "Waiting for container to initialize..."
sleep 10

# Function to execute commands in container
exec_in_container() {
    pct exec $CONTAINER_ID -- bash -c "$1"
}

print_step "Updating package manager..."
if [ "$OS_TYPE" = "debian" ]; then
    exec_in_container "apt update && apt upgrade -y"
else
    exec_in_container "apt update && apt upgrade -y"
fi

print_step "Installing essential packages..."
exec_in_container "apt install -y curl wget git vim htop unzip ca-certificates gnupg lsb-release"

print_step "Installing Docker..."
# Add Docker's official GPG key
exec_in_container "install -m 0755 -d /etc/apt/keyrings"
exec_in_container "curl -fsSL https://download.docker.com/linux/${OS_TYPE}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
exec_in_container "chmod a+r /etc/apt/keyrings/docker.gpg"

# Add Docker repository
exec_in_container "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_TYPE} \$(. /etc/os-release && echo \"\$VERSION_CODENAME\") stable\" | tee /etc/apt/sources.list.d/docker.list > /dev/null"

# Install Docker packages
exec_in_container "apt update"
exec_in_container "apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

print_step "Configuring Docker..."
exec_in_container "systemctl enable docker"
exec_in_container "systemctl start docker"
exec_in_container "usermod -aG docker root"

print_step "Installing Docker Compose (standalone)..."
exec_in_container "curl -L \"https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)\" -o /usr/local/bin/docker-compose"
exec_in_container "chmod +x /usr/local/bin/docker-compose"

print_step "Installing Zig (for building Zepplin)..."
exec_in_container "curl -L https://ziglang.org/download/0.15.0-dev.822+dd75e7bcb/zig-linux-x86_64-0.15.0-dev.822+dd75e7bcb.tar.xz -o /tmp/zig.tar.xz"
exec_in_container "cd /opt && tar -xf /tmp/zig.tar.xz"
exec_in_container "ln -sf /opt/zig-*/zig /usr/local/bin/zig"
exec_in_container "rm /tmp/zig.tar.xz"

print_step "Setting up Zepplin..."
exec_in_container "mkdir -p /opt/zepplin"
exec_in_container "cd /opt/zepplin && git clone https://github.com/ghostkellz/zepplin.git ."
exec_in_container "cd /opt/zepplin && chmod +x dev.sh"

print_step "Building Zepplin..."
exec_in_container "cd /opt/zepplin && ./dev.sh build"

print_step "Creating systemd service..."
pct push $CONTAINER_ID - /etc/systemd/system/zepplin.service <<EOF
[Unit]
Description=Zepplin Package Registry
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/zepplin
ExecStart=/opt/zepplin/zig-out/bin/zepplin serve 8080
Restart=always
RestartSec=10
Environment=ZEPPLIN_DATA_DIR=/var/lib/zepplin

[Install]
WantedBy=multi-user.target
EOF

exec_in_container "mkdir -p /var/lib/zepplin"
exec_in_container "systemctl daemon-reload"
exec_in_container "systemctl enable zepplin"

print_step "Setting up Docker Compose for production deployment..."
pct push $CONTAINER_ID - /opt/zepplin/docker-compose.prod.yml <<EOF
version: '3.8'

services:
  zepplin:
    build: .
    container_name: zepplin-registry
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - zepplin_data:/app/data
    environment:
      - ZEPPLIN_DATA_DIR=/app/data
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/api/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  nginx:
    image: nginx:alpine
    container_name: zepplin-nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - nginx_logs:/var/log/nginx
    depends_on:
      - zepplin

volumes:
  zepplin_data:
  nginx_logs:
EOF

print_step "Setting up firewall rules..."
exec_in_container "apt install -y ufw"
exec_in_container "ufw allow ssh"
exec_in_container "ufw allow 80/tcp"
exec_in_container "ufw allow 443/tcp"
exec_in_container "ufw allow 8080/tcp"
exec_in_container "echo 'y' | ufw enable"

print_step "Creating management scripts..."
pct push $CONTAINER_ID - /opt/zepplin/manage.sh <<'EOF'
#!/bin/bash

case "$1" in
    start)
        systemctl start zepplin
        echo "Zepplin started"
        ;;
    stop)
        systemctl stop zepplin
        echo "Zepplin stopped"
        ;;
    restart)
        systemctl restart zepplin
        echo "Zepplin restarted"
        ;;
    status)
        systemctl status zepplin
        ;;
    logs)
        journalctl -u zepplin -f
        ;;
    docker-up)
        cd /opt/zepplin && docker-compose -f docker-compose.prod.yml up -d
        ;;
    docker-down)
        cd /opt/zepplin && docker-compose -f docker-compose.prod.yml down
        ;;
    build)
        cd /opt/zepplin && ./dev.sh build
        ;;
    update)
        cd /opt/zepplin && git pull && ./dev.sh build && systemctl restart zepplin
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs|docker-up|docker-down|build|update}"
        exit 1
        ;;
esac
EOF

exec_in_container "chmod +x /opt/zepplin/manage.sh"

# Get container IP
CONTAINER_IP=$(pct exec $CONTAINER_ID -- hostname -I | awk '{print $1}')

print_step "Installation completed successfully!"
echo ""
print_info "Container Details:"
print_info "  ID: $CONTAINER_ID"
print_info "  Name: $CONTAINER_NAME"
print_info "  OS: $OS_VERSION"
print_info "  IP: $CONTAINER_IP"
echo ""
print_info "Zepplin Registry URLs:"
print_info "  Direct: http://$CONTAINER_IP:8080"
print_info "  With Nginx: http://$CONTAINER_IP"
echo ""
print_info "Management Commands:"
print_info "  pct enter $CONTAINER_ID                    # Enter container"
print_info "  pct exec $CONTAINER_ID -- /opt/zepplin/manage.sh status  # Check status"
print_info "  pct exec $CONTAINER_ID -- /opt/zepplin/manage.sh logs    # View logs"
echo ""
print_info "Production Deployment:"
print_info "  pct exec $CONTAINER_ID -- /opt/zepplin/manage.sh docker-up   # Start with Docker Compose"
print_info "  pct exec $CONTAINER_ID -- /opt/zepplin/manage.sh docker-down # Stop Docker Compose"
echo ""
print_warning "Next Steps:"
print_warning "1. Configure DNS to point to $CONTAINER_IP"
print_warning "2. Set up SSL certificates for HTTPS"
print_warning "3. Configure backup for /var/lib/zepplin"
print_warning "4. Monitor logs and performance"

echo ""
print_step "Starting Zepplin service..."
exec_in_container "systemctl start zepplin"

print_info "🎉 Zepplin Registry is now running!"
print_info "Visit http://$CONTAINER_IP:8080 to access the web interface"
