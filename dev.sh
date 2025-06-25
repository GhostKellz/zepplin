#!/bin/bash

# Zepplin Development Script
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print banner
echo -e "${BLUE}"
echo "⚡ Zepplin Development Environment"
echo "=================================="
echo -e "${NC}"

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

# Check if Zig is installed
check_zig() {
    if ! command -v zig &> /dev/null; then
        print_error "Zig is not installed. Please install Zig 0.13.0 or later."
        print_info "Download from: https://ziglang.org/download/"
        exit 1
    fi
    
    local zig_version=$(zig version)
    print_info "Using Zig version: $zig_version"
}

# Build the project
build() {
    print_step "Building Zepplin..."
    zig build
    print_info "Build completed successfully!"
}

# Run tests
test() {
    print_step "Running tests..."
    zig build test
    print_info "All tests passed!"
}

# Run the CLI
run_cli() {
    print_step "Running Zepplin CLI..."
    if [ $# -eq 0 ]; then
        ./zig-out/bin/zepplin help
    else
        ./zig-out/bin/zepplin "$@"
    fi
}

# Run the registry server
run_server() {
    local port=${1:-8080}
    print_step "Starting Zepplin Registry Server on port $port..."
    print_info "Access the web interface at: http://localhost:$port"
    print_info "Press Ctrl+C to stop the server"
    ./zig-out/bin/zepplin serve "$port"
}

# Build and run with Docker
docker_build() {
    print_step "Building Docker image..."
    docker build -t zepplin:latest .
    print_info "Docker image built successfully!"
}

docker_run() {
    local port=${1:-8080}
    print_step "Running Zepplin in Docker on port $port..."
    print_info "Access the web interface at: http://localhost:$port"
    docker run --rm -p "$port:8080" zepplin:latest
}

# Development environment with Docker Compose
dev_up() {
    print_step "Starting development environment..."
    docker-compose up --build
}

dev_down() {
    print_step "Stopping development environment..."
    docker-compose down
}

# Clean build artifacts
clean() {
    print_step "Cleaning build artifacts..."
    rm -rf zig-out zig-cache
    print_info "Clean completed!"
}

# Show help
show_help() {
    echo "Zepplin Development Script"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  build              Build the project"
    echo "  test               Run tests"
    echo "  run [args...]      Run the CLI with optional arguments"
    echo "  serve [port]       Run the registry server (default port: 8080)"
    echo "  docker-build       Build Docker image"
    echo "  docker-run [port]  Run in Docker (default port: 8080)"
    echo "  dev-up             Start development environment with Docker Compose"
    echo "  dev-down           Stop development environment"
    echo "  clean              Clean build artifacts"
    echo "  reset-db           Reset the database (when using file-based storage)"
    echo "  demo               Run a demo showcasing all features"
    echo "  help               Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 build                    # Build the project"
    echo "  $0 run init                 # Initialize a new project"
    echo "  $0 run add xev              # Add a package"
    echo "  $0 serve 3000               # Start server on port 3000"
    echo "  $0 docker-run 8080          # Run in Docker on port 8080"
    echo "  $0 demo                     # Show CLI and server features"
    echo ""
    echo "Database Integration:"
    echo "  Current: In-memory storage (demo mode)"
    echo "  Next: zqlite integration for persistent storage"
    echo "  TODO: Fix zqlite hash in build.zig.zon for production use"
}

# Reset database (for when we have persistent storage)
reset_db() {
    print_step "Resetting database..."
    rm -f data/zepplin.db data/packages.db
    print_info "Database reset completed!"
}

# Run a demo showcasing features
demo() {
    print_step "Running Zepplin Demo..."
    
    echo ""
    print_info "1. Building the project..."
    build
    
    echo ""
    print_info "2. Testing CLI commands..."
    ./zig-out/bin/zepplin help
    
    echo ""
    print_info "3. Starting server in background..."
    ./zig-out/bin/zepplin serve 3000 &
    SERVER_PID=$!
    
    # Wait for server to start
    sleep 2
    
    echo ""
    print_info "4. Testing API endpoints..."
    if command -v curl &> /dev/null; then
        echo "Packages list:"
        curl -s http://localhost:3000/api/packages | head -n 5
        echo ""
        echo ""
        echo "Package search:"
        curl -s "http://localhost:3000/api/packages/search?q=zig" | head -n 5
        echo ""
    else
        print_warning "curl not available, skipping API tests"
    fi
    
    echo ""
    print_info "5. Web interface available at: http://localhost:3000"
    print_info "Press Ctrl+C to stop the demo server"
    
    # Clean up
    trap "kill $SERVER_PID 2>/dev/null || true" EXIT
    wait $SERVER_PID
}

# Main script logic
case "${1:-help}" in
    "build")
        check_zig
        build
        ;;
    "test")
        check_zig
        test
        ;;
    "run")
        check_zig
        build
        shift
        run_cli "$@"
        ;;
    "serve")
        check_zig
        build
        run_server "${2:-8080}"
        ;;
    "docker-build")
        docker_build
        ;;
    "docker-run")
        docker_run "${2:-8080}"
        ;;
    "dev-up")
        dev_up
        ;;
    "dev-down")
        dev_down
        ;;
    "clean")
        clean
        ;;
    "reset-db")
        reset_db
        ;;
    "demo")
        demo
        ;;
    "help"|*)
        show_help
        ;;
esac
