#!/bin/bash

# Proxmox LXC Container Setup for Zepplin Registry using Community Docker Script
# 
# This script creates a Docker-enabled LXC container on Proxmox and deploys Zepplin inside it.
# It uses the community Docker setup script and then adds Zepplin-specific configuration.
#
# Usage Examples:
#   ./setup-lxc.sh                                    # Default: ID=100, DHCP
#   ./setup-lxc.sh 101 zepplin-prod                   # Custom ID and name
#   ./setup-lxc.sh 102 zepplin-dev vmbr1             # Custom bridge
#   ./setup-lxc.sh 103 zepplin-test vmbr0 dhcp 9080  # Custom port
#   ./setup-lxc.sh 104 zepplin-static vmbr0 "192.168.1.100/24,gw=192.168.1.1" 8080
#
# Arguments:
#   $1: container_id    (default: 100)
#   $2: container_name  (default: zepplin-registry)  
#   $3: bridge         (default: vmbr0)
#   $4: ip_config      (default: dhcp, or "ip/mask,gw=gateway")
#   $5: zepplin_port   (default: 8080)
#
# Uses: https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/docker.sh
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
echo "🚀 Zepplin Registry - Proxmox LXC Setup with Docker"
echo "=================================================="
echo -e "${NC}"

# Parse arguments
CONTAINER_ID=${1:-100}
CONTAINER_NAME=${2:-zepplin-registry}
BRIDGE=${3:-vmbr0}
IP_CONFIG=${4:-dhcp}  # Can be 'dhcp' or 'static=192.168.1.100/24,gw=192.168.1.1'
ZEPPLIN_PORT=${5:-8080}

print_info "Creating Docker LXC container for Zepplin Registry"
print_info "Container ID: $CONTAINER_ID"
print_info "Container Name: $CONTAINER_NAME"
print_info "Bridge: $BRIDGE"
print_info "IP Config: $IP_CONFIG"
print_info "Zepplin Port: $ZEPPLIN_PORT"

# Download and run the community Docker setup script
print_step "Downloading community Docker LXC setup script..."
wget -O /tmp/docker-lxc-setup.sh https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/docker.sh
chmod +x /tmp/docker-lxc-setup.sh

print_step "Running Docker LXC setup (this will create the container with Docker)..."
# Set environment variables for the community script
export CTID=$CONTAINER_ID
export HOSTNAME=$CONTAINER_NAME
export PCT_OSTYPE=debian
export PCT_OSVERSION=12
export VERBOSE=1

# Run the community script with our parameters
/tmp/docker-lxc-setup.sh

# Wait for container to be ready
print_step "Waiting for container to be fully ready..."
sleep 15

# Check if container was created successfully
if ! pct status $CONTAINER_ID >/dev/null 2>&1; then
    print_error "Container $CONTAINER_ID was not created successfully!"
    exit 1
fi

print_step "Container created successfully, starting if not running..."
pct start $CONTAINER_ID 2>/dev/null || true

# Configure network if static IP was requested
if [[ "$IP_CONFIG" != "dhcp" && "$IP_CONFIG" != "DHCP" ]]; then
    print_step "Configuring static IP: $IP_CONFIG"
    pct set $CONTAINER_ID -net0 name=eth0,bridge=$BRIDGE,ip=$IP_CONFIG
    pct stop $CONTAINER_ID
    sleep 5
    pct start $CONTAINER_ID
fi

sleep 10

# Function to execute commands in container
exec_in_container() {
    pct exec $CONTAINER_ID -- bash -c "$1"
}

print_step "Verifying Docker installation..."
if ! exec_in_container "docker --version" >/dev/null 2>&1; then
    print_error "Docker is not properly installed in container!"
    exit 1
fi

if ! exec_in_container "docker-compose --version" >/dev/null 2>&1; then
    print_warning "docker-compose not found, trying to install..."
    exec_in_container "apt-get update && apt-get install -y docker-compose-plugin"
fi

print_step "Installing curl for healthchecks..."
exec_in_container "apt-get update && apt-get install -y curl"

print_step "Setting up Zepplin deployment directory..."
exec_in_container "mkdir -p /opt/zepplin"

# Option 1: Clone from git (update URL as needed)
# exec_in_container "cd /opt/zepplin && git clone https://github.com/your-username/zepplin.git ."

# Option 2: Copy current project files (for development)
print_info "Copying current project files to container..."
if [ -d "$(pwd)/src" ]; then
    print_info "Found local Zepplin project, copying files..."
    tar czf /tmp/zepplin-project.tar.gz --exclude='.git' --exclude='zig-out' --exclude='.zig-cache' --exclude='data' --exclude='test_db' .
    pct push $CONTAINER_ID /tmp/zepplin-project.tar.gz /tmp/zepplin-project.tar.gz
    exec_in_container "cd /opt/zepplin && tar xzf /tmp/zepplin-project.tar.gz && rm /tmp/zepplin-project.tar.gz"
    rm -f /tmp/zepplin-project.tar.gz
else
    print_warning "No local project found, cloning from git..."
    exec_in_container "cd /opt/zepplin && git clone https://github.com/your-username/zepplin.git ."
fi

print_step "Creating Docker Compose deployment for Zepplin..."
pct push $CONTAINER_ID - /opt/zepplin/docker-compose.yml <<EOF
version: '3.8'

services:
  zepplin:
    build: .
    container_name: zepplin-registry
    restart: unless-stopped
    ports:
      - "${ZEPPLIN_PORT}:8080"
    volumes:
      - zepplin_data:/app/data
      - ./data:/app/data
    environment:
      - ZEPPLIN_DATA_DIR=/app/data
      - ZEPPLIN_PORT=8080
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

volumes:
  zepplin_data:
    driver: local
EOF

print_step "Creating management scripts..."
pct push $CONTAINER_ID - /opt/zepplin/manage.sh <<'EOF'
#!/bin/bash

case "$1" in
    start|up)
        cd /opt/zepplin && docker-compose up -d
        echo "Zepplin containers started"
        ;;
    stop|down)
        cd /opt/zepplin && docker-compose down
        echo "Zepplin containers stopped"
        ;;
    restart)
        cd /opt/zepplin && docker-compose restart
        echo "Zepplin containers restarted"
        ;;
    status)
        cd /opt/zepplin && docker-compose ps
        ;;
    logs)
        cd /opt/zepplin && docker-compose logs -f
        ;;
    build)
        cd /opt/zepplin && docker-compose build
        ;;
    rebuild)
        cd /opt/zepplin && docker-compose down && docker-compose build --no-cache && docker-compose up -d
        echo "Zepplin rebuilt and restarted"
        ;;
    update)
        cd /opt/zepplin && git pull && docker-compose down && docker-compose build && docker-compose up -d
        echo "Zepplin updated and restarted"
        ;;
    shell)
        docker exec -it zepplin-registry /bin/sh
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs|build|rebuild|update|shell}"
        echo "  start/up    - Start Zepplin containers"
        echo "  stop/down   - Stop Zepplin containers"
        echo "  restart     - Restart Zepplin containers"
        echo "  status      - Show container status"
        echo "  logs        - Follow container logs"
        echo "  build       - Build Zepplin image"
        echo "  rebuild     - Rebuild from scratch"
        echo "  update      - Pull updates and rebuild"
        echo "  shell       - Access Zepplin container shell"
        exit 1
        ;;
esac
EOF

exec_in_container "chmod +x /opt/zepplin/manage.sh"

print_step "Building and starting Zepplin containers..."
exec_in_container "cd /opt/zepplin && docker-compose build"
exec_in_container "cd /opt/zepplin && docker-compose up -d"

# Get container IP
CONTAINER_IP=$(pct exec $CONTAINER_ID -- hostname -I | awk '{print $1}' | tr -d '\n')

print_step "Installation completed successfully!"
echo ""
print_info "🎉 Zepplin Registry is now running!"
echo ""
print_info "Container Details:"
print_info "  ID: $CONTAINER_ID"
print_info "  Name: $CONTAINER_NAME"
print_info "  Bridge: $BRIDGE"
print_info "  IP: $CONTAINER_IP"
print_info "  Port: $ZEPPLIN_PORT"
echo ""
print_info "Access URLs:"
print_info "  Internal: http://$CONTAINER_IP:$ZEPPLIN_PORT"
print_info "  Web Interface: http://$CONTAINER_IP:$ZEPPLIN_PORT"
print_info "  API Base: http://$CONTAINER_IP:$ZEPPLIN_PORT/api"
echo ""
print_info "Management Commands:"
print_info "  Enter container:           pct enter $CONTAINER_ID"
print_info "  Check container status:    pct status $CONTAINER_ID"
print_info "  Stop container:            pct stop $CONTAINER_ID"
print_info "  Start container:           pct start $CONTAINER_ID"
echo ""
print_info "Zepplin Management (inside container):"
print_info "  /opt/zepplin/manage.sh status     # Check Zepplin status"
print_info "  /opt/zepplin/manage.sh logs       # View logs"
print_info "  /opt/zepplin/manage.sh start      # Start Zepplin"
print_info "  /opt/zepplin/manage.sh stop       # Stop Zepplin"
print_info "  /opt/zepplin/manage.sh restart    # Restart Zepplin"
print_info "  /opt/zepplin/manage.sh rebuild    # Rebuild from scratch"
print_info "  /opt/zepplin/manage.sh update     # Pull updates and rebuild"
print_info "  /opt/zepplin/manage.sh shell      # Access container shell"
echo ""
print_warning "Production Setup:"
print_warning "1. Configure nginx reverse proxy to: http://$CONTAINER_IP:$ZEPPLIN_PORT"
print_warning "2. Set up SSL certificate for your domain"
print_warning "3. Configure backup for Docker volumes: /var/lib/docker/volumes/zepplin_*"
print_warning "4. Monitor logs: pct exec $CONTAINER_ID -- /opt/zepplin/manage.sh logs"
print_warning "5. Update Zepplin: pct exec $CONTAINER_ID -- /opt/zepplin/manage.sh update"

# Clean up
rm -f /tmp/docker-lxc-setup.sh
