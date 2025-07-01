#!/bin/bash

# 🔧 Quick Fix Script for Zepplin Registry
# Rebuilds and restarts the container with fixes

set -e

INSTALL_DIR="/opt/zepplin"

echo "🔧 Applying Zepplin fixes..."

if [ ! -d "$INSTALL_DIR" ]; then
    echo "❌ Zepplin not found at $INSTALL_DIR. Run install.sh first."
    exit 1
fi

cd "$INSTALL_DIR"

echo "🛑 Stopping current container..."
docker compose down

echo "🔄 Pulling latest changes..."
git pull origin main

echo "🏗️ Rebuilding with latest fixes..."
docker compose build --no-cache

echo "🚀 Starting updated container..."
docker compose up -d

echo "⏳ Waiting for startup..."
sleep 10

echo "🏥 Checking health..."
if curl -s http://localhost:8080/health > /dev/null 2>&1; then
    echo "✅ Health check passed!"
    echo "🎉 Zepplin Registry is running with fixes applied!"
else
    echo "⚠️ Health check failed. Checking container status..."
    docker compose ps
    echo ""
    echo "📋 Recent logs:"
    docker compose logs --tail=20 zepplin
fi

echo ""
echo "🔍 Container status:"
docker compose ps
