#!/bin/bash

# 🚀 Zepplin Registry Installation Script
# For Debian LXC containers with Docker and Docker Compose v2

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
REPO_URL="https://github.com/ghostkellz/zepplin.git"
INSTALL_DIR="/opt/zepplin"
SERVICE_USER="zepplin"
DOMAIN="${ZEPPLIN_DOMAIN:-localhost}"
REGISTRY_NAME="${ZEPPLIN_REGISTRY_NAME:-Zepplin Registry}"

echo -e "${BLUE}🚀 Zepplin Registry Installation Script${NC}"
echo -e "${BLUE}=======================================${NC}"
echo ""

# Function to print status
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root (use sudo)"
   exit 1
fi

# Check prerequisites
print_status "Checking prerequisites..."

# Check Docker
if ! command -v docker &> /dev/null; then
    print_error "Docker is not installed. Please install Docker first."
    exit 1
fi

# Check Docker Compose
if ! docker compose version &> /dev/null; then
    print_error "Docker Compose v2 is not installed. Please install Docker Compose v2 first."
    exit 1
fi

# Check Git
if ! command -v git &> /dev/null; then
    print_status "Installing Git..."
    apt-get update
    apt-get install -y git curl wget
fi

print_status "Prerequisites check passed ✓"

# Create service user
if ! id "$SERVICE_USER" &>/dev/null; then
    print_status "Creating service user: $SERVICE_USER"
    useradd -r -s /bin/false -d "$INSTALL_DIR" "$SERVICE_USER"
fi

# Create installation directory
print_status "Creating installation directory: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

# Clone or update repository
if [ -d "$INSTALL_DIR/.git" ]; then
    print_status "Updating existing repository..."
    cd "$INSTALL_DIR"
    git pull origin main
else
    print_status "Cloning Zepplin repository..."
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

# Set proper ownership
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

# Create required directories
print_status "Creating required directories..."
mkdir -p "$INSTALL_DIR/data"
mkdir -p "$INSTALL_DIR/packages"
mkdir -p "$INSTALL_DIR/backups"
mkdir -p "$INSTALL_DIR/logs"
mkdir -p "/var/log/zepplin"

# Set permissions
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
chown -R "$SERVICE_USER:$SERVICE_USER" "/var/log/zepplin"

# Create environment file
print_status "Creating environment configuration..."
cat > "$INSTALL_DIR/.env" << EOF
# Zepplin Registry Configuration
ZEPPLIN_DOMAIN=$DOMAIN
ZEPPLIN_REGISTRY_NAME=$REGISTRY_NAME
ZEPPLIN_LOG_LEVEL=info
ZEPPLIN_MAX_PACKAGE_SIZE=50MB
ZEPPLIN_ENABLE_WASM=true

# Database configuration
ZEPPLIN_DATA_DIR=/app/data

# Port configuration (internal - nginx will proxy)
ZEPPLIN_PORT=8080

# Security
ZEPPLIN_JWT_SECRET=$(openssl rand -hex 32)
ZEPPLIN_REQUIRE_AUTH=false

# Performance
ZEPPLIN_MAX_CONNECTIONS=100
ZEPPLIN_RATE_LIMIT_ANONYMOUS=60
ZEPPLIN_RATE_LIMIT_AUTHENTICATED=5000
EOF

chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/.env"

# Ensure docker-compose.yml is readable by root (needed for systemd service)
chmod 644 "$INSTALL_DIR/docker-compose.yml"
chmod 644 "$INSTALL_DIR/.env"

# Update docker-compose.yml to use correct paths
print_status "Configuring Docker Compose..."
cat > "$INSTALL_DIR/docker-compose.yml" << 'EOF'
services:
  zepplin:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: zepplin-registry
    restart: unless-stopped
    expose:
      - "8080"
    ports:
      - "127.0.0.1:8080:8080"  # Only bind to localhost
    volumes:
      - zepplin_data:/app/data
      - zepplin_packages:/app/packages
      - ./backups:/app/backups:rw
      - /var/log/zepplin:/app/logs:rw
    env_file:
      - .env
    networks:
      - zepplin-network
    labels:
      - "com.docker.compose.service=zepplin-registry"
      - "org.label-schema.description=Zepplin Zig Package Registry"

  # Database backup service
  backup:
    image: alpine:3.19
    container_name: zepplin-backup
    restart: "no"
    volumes:
      - zepplin_data:/data:ro
      - ./backups:/backups:rw
    command: |
      sh -c '
        apk add --no-cache sqlite
        DATE=$$(date +%Y%m%d_%H%M%S)
        sqlite3 /data/zepplin.db ".backup /backups/zepplin_$$DATE.db"
        find /backups -name "zepplin_*.db" -mtime +7 -delete
        echo "Backup completed: zepplin_$$DATE.db"
      '
    depends_on:
      - zepplin
    networks:
      - zepplin-network
    profiles:
      - backup

networks:
  zepplin-network:
    driver: bridge
    name: zepplin-network

volumes:
  zepplin_data:
    driver: local
    name: zepplin_data
  zepplin_packages:
    driver: local
    name: zepplin_packages
EOF

# Build the Docker image
print_status "Building Zepplin Docker image..."
cd "$INSTALL_DIR"
docker compose build

if [ $? -ne 0 ]; then
    print_error "Docker build failed. Check the logs above."
    exit 1
fi

print_status "Docker image built successfully ✓"

# Create systemd service
print_status "Creating systemd service..."
cat > /etc/systemd/system/zepplin.service << EOF
[Unit]
Description=Zepplin Zig Package Registry
Requires=docker.service
After=docker.service
Wants=network-online.target
After=network-online.target

[Service]
Type=forking
RemainAfterExit=yes
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
ExecReload=/usr/bin/docker compose restart
TimeoutStartSec=300
TimeoutStopSec=120
User=root
Group=root

# Restart policy
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable service
systemctl daemon-reload
systemctl enable zepplin.service



# Create management scripts
print_status "Creating management scripts..."

# Start script
cat > "$INSTALL_DIR/start.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
echo "Starting Zepplin Registry..."
docker compose up -d
echo "Zepplin Registry started!"
echo "Check status with: docker compose ps"
echo "View logs with: docker compose logs -f"
EOF

# Stop script
cat > "$INSTALL_DIR/stop.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
echo "Stopping Zepplin Registry..."
docker compose down
echo "Zepplin Registry stopped!"
EOF

# Status script
cat > "$INSTALL_DIR/status.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
echo "=== Zepplin Registry Status ==="

# Check if docker-compose.yml exists
if [ ! -f "docker-compose.yml" ]; then
    echo "❌ docker-compose.yml not found!"
    exit 1
fi

# Show docker compose status
echo "=== Docker Compose Status ==="
docker compose ps -a

echo ""
echo "=== Container Status Details ==="
if docker compose ps | grep -q "Up"; then
    echo "✅ Container is running"
    
    # Show container details
    echo ""
    echo "=== Container Details ==="
    docker compose ps
    
    echo ""
    echo "=== Recent Container Logs ==="
    docker compose logs --tail=10 zepplin 2>/dev/null || echo "No logs available"
else
    echo "❌ Container is not running"
    echo ""
    echo "=== All Containers (including stopped) ==="
    docker compose ps -a --format "table {{.Name}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
    echo ""
    echo "=== Recent Container Logs (Last 50 lines) ==="
    docker compose logs --tail=50 zepplin 2>/dev/null || echo "No logs available"
    echo ""
    echo "=== Container Inspect (Exit Code) ==="
    docker inspect zepplin-registry --format="{{.State.ExitCode}} - {{.State.Error}}" 2>/dev/null || echo "Container not found"
    echo ""
    echo "=== Systemd Service Status ==="
    systemctl status zepplin --no-pager -l
fi

echo ""
echo "=== Resource Usage ==="
docker stats --no-stream zepplin-registry 2>/dev/null || echo "Container not running"

echo ""
echo "=== Files Check ==="
echo "docker-compose.yml: $(test -f docker-compose.yml && echo "✅ exists" || echo "❌ missing")"
echo ".env: $(test -f .env && echo "✅ exists" || echo "❌ missing")"
echo "Dockerfile: $(test -f Dockerfile && echo "✅ exists" || echo "❌ missing")"
EOF

# Update script
cat > "$INSTALL_DIR/update.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
echo "Updating Zepplin Registry..."
docker compose down
git pull origin main
docker compose build --no-cache
docker compose up -d
echo "Zepplin Registry updated and restarted!"
EOF

# Backup script
cat > "$INSTALL_DIR/backup.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
echo "Creating backup..."
docker compose --profile backup up backup
echo "Backup completed! Check ./backups/ directory"
EOF

# Make scripts executable
chmod +x "$INSTALL_DIR"/*.sh

# Set ownership for all created files
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

# Verify files were created properly
print_status "Verifying installation files..."
cd "$INSTALL_DIR"

if [ ! -f "docker-compose.yml" ]; then
    print_error "docker-compose.yml was not created properly!"
    exit 1
fi

if [ ! -f ".env" ]; then
    print_error ".env file was not created properly!"
    exit 1
fi

if [ ! -f "Dockerfile" ]; then
    print_error "Dockerfile not found! Make sure the repository was cloned properly."
    exit 1
fi

print_status "All required files are present ✓"

# Test docker compose configuration
print_status "Testing Docker Compose configuration..."
if ! docker compose config > /dev/null 2>&1; then
    print_error "Docker Compose configuration is invalid!"
    print_status "Showing docker compose config output:"
    docker compose config
    exit 1
fi

print_status "Docker Compose configuration is valid ✓"

# Start the service
print_status "Starting Zepplin Registry..."
systemctl start zepplin.service

# Wait a moment for startup
sleep 15

# Check if service is running
if systemctl is-active --quiet zepplin.service; then
    print_status "✅ Systemd service is running!"
    
    # Check if container is actually running
    cd "$INSTALL_DIR"
    
    print_status "Checking container status..."
    docker compose ps -a
    
    if docker compose ps | grep -q "Up"; then
        print_status "✅ Container is running!"
    else
        print_warning "⚠️ Service is running but container may have issues. Checking logs..."
        print_status "=== Docker Compose Logs ==="
        docker compose logs --tail=50 zepplin 2>/dev/null || echo "No container logs available"
        print_status "=== Container Exit Status ==="
        docker compose ps -a --format "table {{.Name}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
        print_status "=== Systemd Service Logs ==="
        journalctl -u zepplin.service --no-pager -l --lines=20
    fi
else
    print_error "❌ Service failed to start. Check logs with: journalctl -u zepplin.service -f"
    print_status "=== Systemd Service Logs ==="
    journalctl -u zepplin.service --no-pager -l --lines=20
    print_status "Attempting to get container logs..."
    cd "$INSTALL_DIR"
    docker compose logs --tail=20 zepplin 2>/dev/null || echo "No container logs available"
    exit 1
fi

# Wait for container to stabilize
print_status "Waiting for container to stabilize..."
sleep 5

echo ""
echo -e "${GREEN}🎉 Installation Complete!${NC}"
echo ""
echo -e "${BLUE}Service Information:${NC}"
echo "  • Installation Directory: $INSTALL_DIR"
echo "  • Service User: $SERVICE_USER"
echo "  • Domain: $DOMAIN"
echo "  • Local URL: http://localhost:8080"
if command -v nginx &> /dev/null; then
    echo "  • Public URL: http://$DOMAIN (if nginx is configured)"
fi
echo ""
echo -e "${BLUE}Management Commands:${NC}"
echo "  • Start:   sudo systemctl start zepplin"
echo "  • Stop:    sudo systemctl stop zepplin"
echo "  • Status:  sudo systemctl status zepplin"
echo "  • Logs:    sudo journalctl -u zepplin -f"
echo ""
echo -e "${BLUE}Quick Scripts:${NC}"
echo "  • $INSTALL_DIR/start.sh    - Start the registry"
echo "  • $INSTALL_DIR/stop.sh     - Stop the registry"
echo "  • $INSTALL_DIR/status.sh   - Check status"
echo "  • $INSTALL_DIR/update.sh   - Update to latest version"
echo "  • $INSTALL_DIR/backup.sh   - Create database backup"
echo ""
echo -e "${BLUE}Container Management:${NC}"
echo "  • cd $INSTALL_DIR && docker compose ps"
echo "  • cd $INSTALL_DIR && docker compose logs -f"
echo "  • cd $INSTALL_DIR && docker compose restart"
echo ""

if command -v nginx &> /dev/null; then
    echo -e "${YELLOW}Next Steps:${NC}"
    echo "1. Configure your domain DNS to point to this server"
    echo "2. Set up SSL/TLS with Let's Encrypt:"
    echo "   sudo apt install certbot python3-certbot-nginx"
    echo "   sudo certbot --nginx -d $DOMAIN"
    echo "3. Restart nginx: sudo systemctl reload nginx"
    echo ""
fi

echo -e "${GREEN}Zepplin Registry is ready to use!${NC}"
