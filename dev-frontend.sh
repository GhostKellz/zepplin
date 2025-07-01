#!/bin/bash
set -e

echo "🚀 Starting Zepplin Frontend Development..."

# Check if we're in the right directory
if [ ! -d "frontend" ]; then
    echo "❌ Error: frontend directory not found. Run this from the project root."
    exit 1
fi

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check dependencies
echo "🔍 Checking dependencies..."

if ! command_exists rustc; then
    echo "❌ Rust is not installed. Please install Rust from https://rustup.rs/"
    exit 1
fi

if ! command_exists trunk; then
    echo "📦 Installing Trunk..."
    cargo install trunk
fi

if ! rustup target list --installed | grep -q wasm32-unknown-unknown; then
    echo "📦 Installing wasm32-unknown-unknown target..."
    rustup target add wasm32-unknown-unknown
fi

if command_exists node && [ -f "frontend/package.json" ]; then
    echo "📦 Installing npm dependencies..."
    cd frontend
    npm install
    cd ..
fi

# Build the frontend
echo "🔨 Building frontend..."
cd frontend
./build.sh
cd ..

# Check if the Zig server is already running
if pgrep -f "zig run" > /dev/null; then
    echo "✅ Zig server appears to be running"
else
    echo "🚀 Starting Zig server..."
    zig run src/main.zig &
    SERVER_PID=$!
    echo "🌐 Server PID: $SERVER_PID"
    
    # Give the server a moment to start
    sleep 2
    
    # Register cleanup function
    cleanup() {
        echo "🛑 Stopping server..."
        kill $SERVER_PID 2>/dev/null || true
    }
    trap cleanup EXIT
fi

echo "✅ Frontend built and server running!"
echo "🌐 Visit: http://localhost:8080"
echo "📝 API docs: http://localhost:8080/api/v1/health"
echo ""
echo "To develop the frontend:"
echo "  cd frontend && trunk serve --open"
echo ""
echo "Press Ctrl+C to stop"

# Keep script running if we started the server
if [ ! -z "$SERVER_PID" ]; then
    wait $SERVER_PID
fi