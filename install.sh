#!/bin/bash

# 🚀 Zepplin Registry v0.5.0 - Production Installation Script
# Lightning-fast Zig package registry with CK Technology branding

set -euo pipefail  # Exit on any error, undefined variables, or pipe failures

# Colors for beautiful output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Configuration
readonly SCRIPT_VERSION="0.5.0"
readonly INSTALL_DIR="/opt/zepplin"
readonly SERVICE_USER="zepplin"
readonly SERVICE_NAME="zepplin"
readonly REPO_URL="https://github.com/ghostkellz/zepplin.git"
readonly REQUIRED_MEMORY_MB=512
readonly REQUIRED_DISK_GB=2

# Environment variables with defaults
DOMAIN="${ZEPPLIN_DOMAIN:-localhost}"
REGISTRY_NAME="${ZEPPLIN_REGISTRY_NAME:-Zepplin Registry}"
LOG_LEVEL="${ZEPPLIN_LOG_LEVEL:-info}"

# Function to print colored messages
print_header() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}  🚀 ${CYAN}Zepplin Registry v${SCRIPT_VERSION} Installation${NC}${BLUE}              ║${NC}"
    echo -e "${BLUE}║${NC}     Lightning-fast Zig Package Registry                     ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}     Powered by CK Technology                               ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

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

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to get system memory in MB
get_memory_mb() {
    grep MemTotal /proc/meminfo | awk '{print int($2/1024)}'
}

# Function to get available disk space in GB
get_disk_space_gb() {
    df "$INSTALL_DIR" 2>/dev/null | awk 'NR==2 {print int($4/1024/1024)}' || echo "0"
}

# Function to validate system requirements
check_system_requirements() {
    print_step "Checking system requirements..."
    
    local memory_mb
    memory_mb=$(get_memory_mb)
    if [[ $memory_mb -lt $REQUIRED_MEMORY_MB ]]; then
        print_error "Insufficient memory: ${memory_mb}MB available, ${REQUIRED_MEMORY_MB}MB required"
        return 1
    fi
    print_info "Memory: ${memory_mb}MB ✓"
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root (use sudo)"
        return 1
    fi
    print_info "Root privileges ✓"
    
    # Check OS
    if [[ ! -f /etc/os-release ]]; then
        print_error "Cannot determine OS version"
        return 1
    fi
    
    local os_name
    os_name=$(grep '^NAME=' /etc/os-release | cut -d'"' -f2)
    print_info "Operating System: $os_name ✓"
    
    print_success "System requirements check passed"
}

# Function to install prerequisites
install_prerequisites() {
    print_step "Installing prerequisites..."
    
    # Update package lists
    print_info "Updating package lists..."
    apt-get update -qq
    
    # Install required packages
    local packages=(
        "curl"
        "wget" 
        "git"
        "apt-transport-https"
        "ca-certificates"
        "gnupg"
        "lsb-release"
        "jq"
        "sqlite3"
    )
    
    print_info "Installing required packages: ${packages[*]}"
    apt-get install -y "${packages[@]}" >/dev/null
    
    # Install Docker if not present
    if ! command_exists docker; then
        print_info "Installing Docker..."
        curl -fsSL https://get.docker.com | sh >/dev/null
        systemctl enable docker
        systemctl start docker
    else
        print_info "Docker already installed ✓"
    fi
    
    # Install Docker Compose if not present
    if ! docker compose version >/dev/null 2>&1; then
        print_info "Installing Docker Compose..."
        local compose_version
        compose_version=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
        curl -L "https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-$(uname -s)-$(uname -m)" \
            -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    else
        print_info "Docker Compose already installed ✓"
    fi
    
    print_success "Prerequisites installed successfully"
}

# Function to create service user and directories
setup_user_and_directories() {
    print_step "Setting up user and directories..."
    
    # Create service user
    if ! id "$SERVICE_USER" &>/dev/null; then
        print_info "Creating service user: $SERVICE_USER"
        useradd -r -s /bin/false -d "$INSTALL_DIR" "$SERVICE_USER"
        usermod -aG docker "$SERVICE_USER"
    else
        print_info "Service user $SERVICE_USER already exists ✓"
    fi
    
    # Create directories
    print_info "Creating application directories..."
    mkdir -p "$INSTALL_DIR"/{data,packages,backups,logs}
    mkdir -p "/var/log/$SERVICE_NAME"
    
    # Set permissions
    chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
    chown -R "$SERVICE_USER:$SERVICE_USER" "/var/log/$SERVICE_NAME"
    chmod -R 755 "$INSTALL_DIR"
    
    print_success "User and directories configured"
}

# Function to clone or update repository
setup_repository() {
    print_step "Setting up repository..."
    
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        print_info "Updating existing repository..."
        cd "$INSTALL_DIR"
        git fetch origin
        git reset --hard origin/main
        git clean -fd
    else
        print_info "Cloning Zepplin repository..."
        rm -rf "$INSTALL_DIR"
        git clone "$REPO_URL" "$INSTALL_DIR"
        cd "$INSTALL_DIR"
    fi
    
    # Ensure proper ownership
    chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
    
    print_success "Repository setup complete"
}

# Function to create environment configuration
create_environment_config() {
    print_step "Creating environment configuration..."
    
    local jwt_secret
    jwt_secret=$(openssl rand -hex 32)
    
    cat > "$INSTALL_DIR/.env" << EOF
# Zepplin Registry v${SCRIPT_VERSION} Configuration
# Generated on $(date)

# Basic Configuration
ZEPPLIN_VERSION=${SCRIPT_VERSION}
ZEPPLIN_DOMAIN=${DOMAIN}
ZEPPLIN_REGISTRY_NAME=${REGISTRY_NAME}
ZEPPLIN_LOG_LEVEL=${LOG_LEVEL}

# Features
ZEPPLIN_ENABLE_WASM=true
ZEPPLIN_MAX_PACKAGE_SIZE=50MB

# Database (SQLite embedded)
ZEPPLIN_DATA_DIR=/app/data

# Network
ZEPPLIN_PORT=8080
ZEPPLIN_HOST=0.0.0.0

# Security
ZEPPLIN_SECRET_KEY=${jwt_secret}
ZEPPLIN_BIND_ADDRESS=0.0.0.0
ZEPPLIN_DB_PATH=/app/data/zepplin.db
ZEPPLIN_STORAGE_PATH=/app/data

# Performance
ZEPPLIN_MAX_CONNECTIONS=100
ZEPPLIN_RATE_LIMIT_ANONYMOUS=60
ZEPPLIN_RATE_LIMIT_AUTHENTICATED=5000

# CK Technology Branding
ZEPPLIN_POWERED_BY=CK Technology
ZEPPLIN_SUPPORT_URL=https://cktech.org
EOF
    
    chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"
    
    print_success "Environment configuration created"
}

# Function to validate Docker setup
validate_docker_setup() {
    print_step "Validating Docker configuration..."
    
    cd "$INSTALL_DIR"
    
    # Validate docker-compose.yml
    if ! docker compose config >/dev/null 2>&1; then
        print_error "Docker Compose configuration is invalid!"
        docker compose config
        return 1
    fi
    print_info "Docker Compose configuration is valid ✓"
    
    # Check if required files exist
    local required_files=(
        "Dockerfile"
        "docker-compose.yml"
        ".env"
        "web/templates/index.html"
        "web/css/style.css"
        "web/js/main.js"
        "assets/CKTech-Logo_Brand.png"
    )
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            print_error "Required file missing: $file"
            return 1
        fi
    done
    print_info "All required files present ✓"
    
    print_success "Docker setup validation passed"
}

# Function to build and start services
build_and_start_services() {
    print_step "Building and starting Zepplin services..."
    
    cd "$INSTALL_DIR"
    
    # Stop any existing containers
    print_info "Stopping existing containers..."
    docker compose down --remove-orphans 2>/dev/null || true
    
    # Build with no cache for clean build
    print_info "Building Docker image (this may take a few minutes)..."
    if ! docker compose build --no-cache; then
        print_error "Docker build failed"
        return 1
    fi
    print_info "Docker image built successfully ✓"
    
    # Start services
    print_info "Starting Zepplin services..."
    if ! docker compose up -d; then
        print_error "Failed to start services"
        return 1
    fi
    
    # Give containers time to initialize
    print_info "Waiting for containers to initialize..."
    sleep 5
    
    # Verify containers are still running
    if ! docker compose ps --services --filter "status=running" | grep -q "zepplin-registry"; then
        print_warning "Container may have crashed, checking logs..."
        docker compose logs --tail=50 zepplin-registry
        print_info "Attempting to restart..."
        docker compose restart
        sleep 5
    fi
    
    print_success "Services started successfully"
}

# Function to create systemd service
create_systemd_service() {
    print_step "Creating systemd service..."
    
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Zepplin Zig Package Registry v${SCRIPT_VERSION}
Documentation=https://github.com/ghostkellz/zepplin
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
ExecReload=/usr/bin/docker compose restart
TimeoutStartSec=300
TimeoutStopSec=120
User=root
Group=root

# Security
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=${INSTALL_DIR}
ReadWritePaths=/var/log/${SERVICE_NAME}

# Restart policy
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd and enable service
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service"
    
    # Start the service
    print_info "Starting systemd service..."
    systemctl start "${SERVICE_NAME}.service"
    
    print_success "Systemd service created, enabled and started"
}

# Function to wait for service health
wait_for_service_health() {
    print_step "Waiting for Zepplin to become healthy..."
    
    local max_attempts=30
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if curl -sf "http://localhost:8080/health" >/dev/null 2>&1; then
            print_success "Zepplin is healthy and responding!"
            return 0
        fi
        
        printf "."
        sleep 2
        ((attempt++))
    done
    
    print_error "Zepplin failed to become healthy within 60 seconds"
    return 1
}

# Function to verify installation
verify_installation() {
    print_step "Verifying installation..."
    
    cd "$INSTALL_DIR"
    
    # Check container status
    print_info "Checking container status..."
    local container_status
    container_status=$(cd "$INSTALL_DIR" && docker compose ps --format json 2>/dev/null || echo "[]")
    
    if ! echo "$container_status" | jq -e '.[] | select(.Service == "zepplin-registry" and .State == "running")' >/dev/null 2>&1; then
        print_error "Zepplin container is not running"
        print_info "Container status:"
        cd "$INSTALL_DIR" && docker compose ps
        print_info "Recent logs:"
        cd "$INSTALL_DIR" && docker compose logs --tail=20 zepplin-registry
        return 1
    fi
    print_info "Container is running ✓"
    
    # Check health endpoint
    if ! curl -sf "http://localhost:8080/health" >/dev/null; then
        print_error "Health endpoint is not responding"
        return 1
    fi
    print_info "Health endpoint responding ✓"
    
    # Check web interface
    if ! curl -sf "http://localhost:8080/" >/dev/null; then
        print_error "Web interface is not responding"
        return 1
    fi
    print_info "Web interface responding ✓"
    
    # Check systemd service
    if ! systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        print_warning "Systemd service is not active"
    else
        print_info "Systemd service is active ✓"
    fi
    
    print_success "Installation verification completed"
}

# Function to create management scripts
create_management_scripts() {
    print_step "Creating management scripts..."
    
    # Enhanced status script
    cat > "$INSTALL_DIR/status.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"

echo "🚀 Zepplin Registry Status Report"
echo "================================="
echo ""

# Container status
echo "📦 Container Status:"
docker compose ps
echo ""

# Health check
echo "🏥 Health Check:"
if curl -sf http://localhost:8080/health >/dev/null 2>&1; then
    echo "✅ Healthy - API responding"
else
    echo "❌ Unhealthy - API not responding"
fi
echo ""

# Resource usage
echo "📊 Resource Usage:"
docker stats --no-stream zepplin-registry 2>/dev/null || echo "Container not running"
echo ""

# Recent logs
echo "📝 Recent Logs (last 10 lines):"
docker compose logs --tail=10 zepplin-registry
EOF

    # Quick restart script
    cat > "$INSTALL_DIR/restart.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
echo "🔄 Restarting Zepplin Registry..."
docker compose restart
echo "✅ Restart complete!"
./status.sh
EOF

    # Update script
    cat > "$INSTALL_DIR/update.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
echo "🔄 Updating Zepplin Registry..."
docker compose down
git pull origin main
docker compose build --no-cache
docker compose up -d
echo "✅ Update complete!"
sleep 5
./status.sh
EOF

    # Backup script
    cat > "$INSTALL_DIR/backup.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
BACKUP_FILE="./backups/zepplin_$(date +%Y%m%d_%H%M%S).db"
mkdir -p ./backups

echo "💾 Creating database backup..."
if docker compose exec zepplin-registry sqlite3 /app/data/zepplin.db ".backup /app/backups/$(basename "$BACKUP_FILE")"; then
    echo "✅ Backup created: $BACKUP_FILE"
else
    echo "❌ Backup failed"
    exit 1
fi

# Clean old backups (keep last 7 days)
find ./backups -name "zepplin_*.db" -mtime +7 -delete
echo "🧹 Old backups cleaned"
EOF

    # Make scripts executable
    chmod +x "$INSTALL_DIR"/*.sh
    chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"/*.sh
    
    print_success "Management scripts created"
}

# Function to print final summary
print_installation_summary() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}  🎉 ${CYAN}Installation Complete!${NC}${GREEN}                               ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}📍 Service Information:${NC}"
    echo "   • Version: $SCRIPT_VERSION"
    echo "   • Installation: $INSTALL_DIR"
    echo "   • User: $SERVICE_USER"
    echo "   • Domain: $DOMAIN"
    echo "   • Local URL: http://localhost:8080"
    echo ""
    echo -e "${BLUE}🎛️  Management Commands:${NC}"
    echo "   • Status:  $INSTALL_DIR/status.sh"
    echo "   • Restart: $INSTALL_DIR/restart.sh"
    echo "   • Update:  $INSTALL_DIR/update.sh"
    echo "   • Backup:  $INSTALL_DIR/backup.sh"
    echo ""
    echo -e "${BLUE}🔧 System Commands:${NC}"
    echo "   • Start:   sudo systemctl start $SERVICE_NAME"
    echo "   • Stop:    sudo systemctl stop $SERVICE_NAME"
    echo "   • Status:  sudo systemctl status $SERVICE_NAME"
    echo "   • Logs:    sudo journalctl -u $SERVICE_NAME -f"
    echo ""
    echo -e "${BLUE}🐳 Docker Commands:${NC}"
    echo "   • Logs:    cd $INSTALL_DIR && docker compose logs -f"
    echo "   • Shell:   cd $INSTALL_DIR && docker compose exec zepplin-registry sh"
    echo "   • Rebuild: cd $INSTALL_DIR && docker compose build --no-cache"
    echo ""
    echo -e "${PURPLE}🚀 Zepplin Registry is ready to serve Zig packages!${NC}"
    echo -e "${CYAN}   Powered by CK Technology${NC}"
    echo ""
}

# Main installation function
main() {
    # Trap errors for cleanup
    trap 'print_error "Installation failed on line $LINENO"' ERR
    
    print_header
    
    check_system_requirements
    install_prerequisites
    setup_user_and_directories
    setup_repository
    create_environment_config
    validate_docker_setup
    build_and_start_services
    create_systemd_service
    wait_for_service_health
    verify_installation
    create_management_scripts
    
    print_installation_summary
}

# Run main function
main "$@"