#!/bin/bash

# Proxmox LXC Container Setup for Zepplin Registry using Community Docker Script
# Usage: ./setup-lxc.sh <container_id> <container_name> [bridge] [ip_type]
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
IP_TYPE=${4:-dhcp}

print_info "Creating Docker LXC container for Zepplin Registry"
print_info "Container ID: $CONTAINER_ID"
print_info "Container Name: $CONTAINER_NAME"
print_info "Bridge: $BRIDGE"
print_info "IP Type: $IP_TYPE"

# Download and run the community Docker setup script
print_step "Downloading community Docker LXC setup script..."
wget -O /tmp/docker-lxc-setup.sh https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/docker.sh
chmod +x /tmp/docker-lxc-setup.sh

print_step "Running Docker LXC setup (this will create the container with Docker)..."
# Run the community script with our parameters
CTID=$CONTAINER_ID HOSTNAME=$CONTAINER_NAME /tmp/docker-lxc-setup.sh

# Wait for container to be ready
print_step "Waiting for container to be fully ready..."
sleep 15

# Function to execute commands in container
exec_in_container() {
    pct exec $CONTAINER_ID -- bash -c "$1"
}

print_step "Verifying Docker installation..."
exec_in_container "docker --version"
exec_in_container "docker-compose --version"

print_step "Setting up Zepplin deployment directory..."
exec_in_container "mkdir -p /opt/zepplin"
exec_in_container "cd /opt/zepplin && git clone https://github.com/ghostkellz/zepplin.git ."

print_step "Creating Docker Compose deployment for Zepplin..."
pct push $CONTAINER_ID - /opt/zepplin/docker-compose.yml <<EOF
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
      - ./data:/app/data
    environment:
      - ZEPPLIN_DATA_DIR=/app/data
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/api/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

volumes:
  zepplin_data:
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
CONTAINER_IP=$(pct exec $CONTAINER_ID -- hostname -I | awk '{print $1}')

print_step "Installation completed successfully!"
echo ""
print_info "Container Details:"
print_info "  ID: $CONTAINER_ID"
print_info "  Name: $CONTAINER_NAME"
print_info "  Bridge: $BRIDGE"
print_info "  IP: $CONTAINER_IP"
echo ""
print_info "Zepplin Registry URL:"
print_info "  http://$CONTAINER_IP:8080"
echo ""
print_info "Management Commands:"
print_info "  pct enter $CONTAINER_ID                           # Enter container"
print_info "  pct exec $CONTAINER_ID -- /opt/zepplin/manage.sh status   # Check status"
print_info "  pct exec $CONTAINER_ID -- /opt/zepplin/manage.sh logs     # View logs"
print_info "  pct exec $CONTAINER_ID -- /opt/zepplin/manage.sh start    # Start containers"
print_info "  pct exec $CONTAINER_ID -- /opt/zepplin/manage.sh stop     # Stop containers"
echo ""
print_info "Docker Commands (inside container):"
print_info "  /opt/zepplin/manage.sh start     # Start Zepplin"
print_info "  /opt/zepplin/manage.sh stop      # Stop Zepplin"
print_info "  /opt/zepplin/manage.sh restart   # Restart Zepplin"
print_info "  /opt/zepplin/manage.sh rebuild   # Rebuild from scratch"
print_info "  /opt/zepplin/manage.sh update    # Pull updates and rebuild"
print_info "  /opt/zepplin/manage.sh shell     # Access container shell"
echo ""
print_warning "Next Steps:"
print_warning "1. Configure your nginx reverse proxy to point to $CONTAINER_IP:8080"
print_warning "2. Configure backup for Docker volumes"
print_warning "3. Monitor logs with: /opt/zepplin/manage.sh logs"

echo ""
print_info "🎉 Zepplin Registry is now running in Docker containers!"
print_info "Visit http://$CONTAINER_IP:8080 to access the web interface"

# Clean up
rm -f /tmp/docker-lxc-setup.sh
