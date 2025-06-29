# 🚀 Zepplin Deployment Guide

> Complete guide for deploying Zepplin in production with external nginx

## 📋 Overview

Zepplin is now production-ready with the following features:
- ✅ **SQLite Backend** - Fast, reliable, persistent storage
- ✅ **Zigistry Integration** - Package discovery and browsing
- ✅ **Modern Web UI** - Beautiful interface with tabbed discovery
- ✅ **RESTful API** - Full API for package management
- ✅ **Docker Support** - Containerized deployment
- ✅ **External nginx Ready** - Designed to work behind reverse proxy

---

## 🐳 Docker Deployment (Recommended)

### 1. Build the Container

```bash
# Clone and build
git clone <your-repo-url>
cd zepplin

# Build Docker image
docker build -t zepplin:latest .
```

### 2. Run with Docker Compose

```bash
# Start Zepplin (exposes port 8080)
docker-compose up -d

# Check logs
docker-compose logs -f zepplin

# Stop
docker-compose down
```

The container will:
- Expose Zepplin on port 8080
- Persist data in `/data` volume
- Run as non-root user for security
- Include SQLite3 for database functionality

---

## 🌐 nginx Configuration

### Basic Reverse Proxy

```nginx
# /etc/nginx/sites-available/zepplin
server {
    listen 80;
    server_name packages.yourcompany.com;
    
    # Redirect to HTTPS
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name packages.yourcompany.com;
    
    # SSL Configuration
    ssl_certificate /path/to/your/certificate.crt;
    ssl_certificate_key /path/to/your/private.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512;
    
    # Rate limiting
    limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=downloads:10m rate=50r/s;
    
    # Proxy to Zepplin
    location / {
        proxy_pass http://localhost:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # WebSocket support (if needed)
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    
    # API rate limiting
    location /api/ {
        limit_req zone=api burst=20 nodelay;
        proxy_pass http://localhost:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    
    # Package downloads with higher rate limit
    location /api/packages/ {
        limit_req zone=downloads burst=100 nodelay;
        proxy_pass http://localhost:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # Cache package metadata
        proxy_cache_valid 200 1h;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
    }
    
    # Security headers
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
}
```

### Advanced nginx Setup with Caching

```nginx
# /etc/nginx/nginx.conf additions
http {
    # Cache configuration
    proxy_cache_path /var/cache/nginx/zepplin 
                     levels=1:2 
                     keys_zone=zepplin_cache:10m 
                     max_size=1g 
                     inactive=60m 
                     use_temp_path=off;
    
    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript 
               application/javascript application/xml+rss 
               application/json application/xml;
    
    include /etc/nginx/sites-enabled/*;
}
```

### Enable the Site

```bash
# Link configuration
sudo ln -s /etc/nginx/sites-available/zepplin /etc/nginx/sites-enabled/

# Test configuration
sudo nginx -t

# Reload nginx
sudo systemctl reload nginx
```

---

## 🔧 Manual Installation (Alternative)

### 1. Prerequisites

```bash
# Install SQLite3
sudo apt-get update
sudo apt-get install sqlite3 libsqlite3-dev

# Install Zig (if not already installed)
curl -L https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz | tar -xJ
sudo mv zig-linux-x86_64-0.13.0 /opt/zig
echo 'export PATH=/opt/zig:$PATH' >> ~/.bashrc
source ~/.bashrc
```

### 2. Build and Install

```bash
# Clone repository
git clone <your-repo-url>
cd zepplin

# Build
zig build -Doptimize=ReleaseFast

# Create installation directory
sudo mkdir -p /opt/zepplin
sudo cp zig-out/bin/zepplin /opt/zepplin/
sudo cp -r data/ /opt/zepplin/data/

# Create systemd service
sudo cp deployment/zepplin.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable zepplin
sudo systemctl start zepplin
```

### 3. Systemd Service

```ini
# /etc/systemd/system/zepplin.service
[Unit]
Description=Zepplin Package Registry
After=network.target

[Service]
Type=simple
User=zepplin
Group=zepplin
WorkingDirectory=/opt/zepplin
ExecStart=/opt/zepplin/zepplin serve 8080
Restart=always
RestartSec=5
Environment=ZEPPLIN_DATA_DIR=/opt/zepplin/data

[Install]
WantedBy=multi-user.target
```

---

## 🔍 Verification & Testing

### 1. Health Check

```bash
# Test basic connectivity
curl http://localhost:8080/

# Test API
curl http://localhost:8080/api/packages

# Test Zigistry discovery
curl "http://localhost:8080/api/zigistry/discover?q=json"

# Test trending packages
curl http://localhost:8080/api/zigistry/trending
```

### 2. CLI Testing

```bash
# Build and test CLI
./zig-out/bin/zepplin help

# Test discovery features
./zig-out/bin/zepplin discover "web framework"
./zig-out/bin/zepplin trending
./zig-out/bin/zepplin browse --category=cli
```

### 3. Web Interface

Visit your deployed URL and verify:
- [ ] Homepage loads with statistics
- [ ] Package search works
- [ ] Zigistry discovery tab functions
- [ ] Trending packages display
- [ ] Category browsing works

---

## 📊 Monitoring

### 1. Log Files

```bash
# Docker logs
docker-compose logs -f zepplin

# systemd logs
sudo journalctl -u zepplin -f

# nginx logs
sudo tail -f /var/log/nginx/access.log
sudo tail -f /var/log/nginx/error.log
```

### 2. Health Monitoring

```bash
# Create health check script
#!/bin/bash
# /opt/zepplin/health-check.sh

response=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/)
if [ $response -eq 200 ]; then
    echo "Zepplin is healthy"
    exit 0
else
    echo "Zepplin health check failed: HTTP $response"
    exit 1
fi
```

### 3. Performance Monitoring

- Monitor SQLite database size: `/opt/zepplin/data/zepplin.db`
- Track API response times via nginx access logs
- Monitor Docker container resource usage
- Set up alerts for error rates

---

## 🔐 Security Considerations

### 1. File Permissions

```bash
# Set proper ownership
sudo useradd -r -s /bin/false zepplin
sudo chown -R zepplin:zepplin /opt/zepplin
sudo chmod 755 /opt/zepplin
sudo chmod 644 /opt/zepplin/data/zepplin.db
```

### 2. Firewall Configuration

```bash
# Allow only nginx to access Zepplin
sudo ufw allow from 127.0.0.1 to any port 8080

# Allow HTTPS traffic
sudo ufw allow 443/tcp
sudo ufw allow 80/tcp
```

### 3. SSL/TLS

- Use Let's Encrypt for free SSL certificates
- Configure strong SSL ciphers in nginx
- Enable HSTS headers
- Consider certificate pinning for high-security environments

---

## 🚀 Production Checklist

### Pre-Deployment
- [ ] SSL certificates configured
- [ ] nginx configuration tested
- [ ] Rate limiting configured
- [ ] Monitoring setup complete
- [ ] Backup strategy defined

### Deployment
- [ ] Docker image built and tested
- [ ] Container deployed with proper volumes
- [ ] nginx proxy configured and tested
- [ ] Health checks passing
- [ ] Logs are being captured

### Post-Deployment
- [ ] Web interface accessible
- [ ] API endpoints responding
- [ ] Zigistry integration working
- [ ] Performance monitoring active
- [ ] Security headers present

---

## 📈 Scaling Considerations

### Horizontal Scaling
- Run multiple Zepplin containers behind nginx load balancer
- Use shared storage for SQLite database (NFS/EFS)
- Consider Redis for session storage if needed

### Database Scaling
- Monitor SQLite performance and size
- Consider PostgreSQL migration for >10GB datasets
- Implement database connection pooling
- Regular database maintenance (VACUUM, ANALYZE)

### CDN Integration
- Serve static assets via CDN
- Cache package downloads at edge locations
- Use nginx caching for API responses

---

## 🔄 Backup & Recovery

### Database Backup
```bash
# Daily backup script
#!/bin/bash
DATE=$(date +%Y%m%d_%H%M%S)
sqlite3 /opt/zepplin/data/zepplin.db ".backup /backup/zepplin_$DATE.db"
find /backup -name "zepplin_*.db" -mtime +7 -delete
```

### Container Backup
```bash
# Backup Docker volumes
docker run --rm -v zepplin_data:/data -v /backup:/backup alpine tar czf /backup/zepplin_data_$(date +%Y%m%d).tar.gz -C /data .
```

---

## 📞 Support & Troubleshooting

### Common Issues

1. **Container won't start**: Check port conflicts and volume permissions
2. **nginx 502 errors**: Verify Zepplin is running on port 8080
3. **Database locked**: Check file permissions and SQLite version
4. **Slow API responses**: Review nginx caching and rate limiting

### Debug Commands
```bash
# Check container status
docker-compose ps
docker-compose logs zepplin

# Test direct connection
curl -v http://localhost:8080/

# Check database
sqlite3 /opt/zepplin/data/zepplin.db ".tables"
```

---

**🎉 Congratulations!** Your Zepplin registry is now production-ready and integrated with nginx. You can now serve Zig packages to your team or organization with a fast, reliable, and beautiful package registry.
