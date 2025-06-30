# 🚀 Zepplin v0.3.0 Deployment Guide

## For zig.cktech.org / zig.cktech.dev

### Prerequisites
- Docker & Docker Compose
- Nginx reverse proxy
- SSL certificates for your domain
- Access to docker.cktechx.io registry (optional)

## Quick Network Deployment

### 1. Clone and Configure
```bash
git clone <zepplin-repo>
cd zepplin
cp .env.example .env
# Edit .env with your domain and settings
```

### 2. Build and Deploy with Docker Compose
```bash
# Build and start services
docker-compose up -d

# Check status
docker-compose ps
docker-compose logs -f zepplin

# Create backups directory
mkdir -p backups
```

### 3. Push to Your Docker Registry (Optional)
```bash
# Tag for your registry
docker tag zepplin:latest docker.cktechx.io/zepplin:0.3.0
docker tag zepplin:latest docker.cktechx.io/zepplin:latest

# Push to your registry
docker push docker.cktechx.io/zepplin:0.3.0
docker push docker.cktechx.io/zepplin:latest
```

### 4. Configure Nginx Proxy
```bash
# Copy nginx config
sudo cp nginx-cktech.conf /etc/nginx/sites-available/zig.cktech.org
sudo ln -s /etc/nginx/sites-available/zig.cktech.org /etc/nginx/sites-enabled/

# Test and reload nginx
sudo nginx -t
sudo systemctl reload nginx
```

### 5. SSL Setup (Let's Encrypt)
```bash
# Install certbot
sudo apt install certbot python3-certbot-nginx

# Get certificates
sudo certbot --nginx -d zig.cktech.org -d zig.cktech.dev

# Auto-renewal
sudo crontab -e
# Add: 0 12 * * * /usr/bin/certbot renew --quiet
```

## Container Network Configuration

### Docker Compose Features
- **Isolated Network**: `zepplin-network` for container communication
- **Health Checks**: Automatic container health monitoring  
- **Persistent Volumes**: Data and package storage
- **Backup Service**: Automated SQLite backups
- **Environment Variables**: Flexible configuration

### Container Communication
```bash
# Access container network
docker network inspect zepplin-network

# Container-to-container communication
# Nginx proxy -> zepplin-registry:8080

# Direct container access (debugging)
docker exec -it zepplin-registry /bin/sh
```

## WASM Support 🕷️

Zepplin v0.3.0 includes **optional WASM support** for Zig packages:

### WASM Package Features
- **WASM Target Detection**: Automatically detect `wasm32-*` targets
- **WASM-Specific Metadata**: Store WASM binary size, exports, imports
- **Web Preview**: Inline WASM module execution in browser
- **WASI Support**: WebAssembly System Interface packages

### WASM Package Types
1. **Browser Libraries**: WASM modules for web applications
2. **WASI Applications**: Standalone WASM applications  
3. **Embedded WASM**: WASM for edge computing/IoT
4. **Game Engines**: WASM game libraries

### Enable WASM Support
```bash
# In .env file
ZEPPLIN_ENABLE_WASM=true

# Or environment variable
export ZEPPLIN_ENABLE_WASM=true
```

### WASM Package Publishing
```bash
# Publish a WASM-enabled Zig package
zepplin add my-wasm-lib --target=wasm32-freestanding
zepplin add my-wasi-app --target=wasm32-wasi

# WASM packages show additional metadata:
# - Binary size
# - Target (browser/wasi/freestanding)  
# - Exported functions
# - Memory requirements
```

### WASM Web Preview
The web UI includes a **WASM execution sandbox** for compatible packages:
- Live WASM module demo
- Function call interface
- Performance metrics
- Browser compatibility check

## Production Checklist

### Security
- [ ] Change default secret keys in `.env`
- [ ] Enable rate limiting (configured in nginx)
- [ ] Set up SSL certificates  
- [ ] Configure firewall rules
- [ ] Enable container security scanning

### Monitoring
- [ ] Set up log aggregation
- [ ] Configure health check endpoints
- [ ] Enable metrics collection (Prometheus)
- [ ] Set up alerting (Discord/Slack webhooks)

### Backup & Recovery
- [ ] Test database backup/restore
- [ ] Configure package storage backup
- [ ] Document recovery procedures
- [ ] Test disaster recovery

### Performance
- [ ] Configure nginx caching
- [ ] Optimize container resource limits
- [ ] Set up CDN (CloudFlare/AWS) for static assets
- [ ] Enable gzip compression

## Maintenance Commands

```bash
# View logs
docker-compose logs -f

# Restart services  
docker-compose restart

# Update to new version
docker-compose pull
docker-compose up -d

# Manual backup
docker-compose run --rm backup

# Scale for high availability
docker-compose up -d --scale zepplin=3

# Monitor resource usage
docker stats zepplin-registry
```

## Troubleshooting

### Common Issues
1. **Container won't start**: Check logs with `docker-compose logs zepplin`
2. **Nginx 502 errors**: Verify container is running and network connectivity  
3. **SSL issues**: Check certificate paths in nginx config
4. **Database corruption**: Restore from backup in `./backups/`

### Health Checks
```bash
# Container health
curl http://localhost:8080/health

# Through nginx proxy  
curl https://zig.cktech.org/health

# API availability
curl https://zig.cktech.org/api/v1/stats
```

## Integration with Existing Services

### Registry Migration
If migrating from another registry:
```bash
# Import packages from old registry
zepplin import --from=old-registry.com --auth-token=<token>

# Bulk package migration
zepplin migrate --source=/path/to/old/packages
```

### CI/CD Integration
```yaml
# GitHub Actions example
- name: Publish to Zepplin
  run: |
    zepplin login --registry=https://zig.cktech.org --token=${{ secrets.ZEPPLIN_TOKEN }}
    zepplin publish
```

---

## 🎯 Your Zepplin Registry is Ready!

Access your registry at:
- **Web UI**: https://zig.cktech.org
- **API**: https://zig.cktech.org/api/v1
- **CLI**: `zepplin config set registry https://zig.cktech.org`

The lightning-fast Zig package registry with beautiful dark blue UI and optional WASM support is now live! ⚡