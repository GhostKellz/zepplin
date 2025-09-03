# Zepplin Production Deployment Guide

## Environment Overview
- **Host**: Production Docker host with existing nginx and SSL certificates
- **Domain**: zig.cktech.org
- **SSL**: Let's Encrypt certificates already configured on host
- **Nginx**: Already running on host (not containerized)
- **SSO**: Azure AD (M365) and GitHub OAuth integration

## Pre-Deployment Checklist

### 1. Required Environment Variables
Create a `.env` file in the project root:

```bash
# Core Configuration
ZEPPLIN_SECRET_KEY=<generate-strong-secret-key>
ZEPPLIN_DOMAIN=zig.cktech.org
ZEPPLIN_REGISTRY_NAME=CKTech Zig Registry
ZEPPLIN_LOG_LEVEL=info

# Azure AD (M365) SSO
AZURE_TENANT_ID=<your-azure-tenant-id>
AZURE_CLIENT_ID=<your-azure-app-client-id>
AZURE_CLIENT_SECRET=<your-azure-app-client-secret>

# GitHub SSO
GITHUB_CLIENT_ID=<your-github-oauth-app-id>
GITHUB_CLIENT_SECRET=<your-github-oauth-app-secret>

# OAuth Configuration
REDIRECT_BASE_URL=https://zig.cktech.org
JWT_SECRET=<generate-another-strong-secret>

# Optional Zigistry Mirror
ZEPPLIN_ZIGISTRY_URL=
```

### 2. Generate Secrets
```bash
# Generate ZEPPLIN_SECRET_KEY
openssl rand -hex 32

# Generate JWT_SECRET
openssl rand -hex 32
```

### 3. Azure AD Configuration
1. In Azure Portal → App Registrations
2. Redirect URI: `https://zig.cktech.org/api/v1/auth/azure/callback`
3. Supported account types: Your tenant only (or as needed)
4. Grant admin consent for required permissions

### 4. GitHub OAuth App Configuration
1. GitHub Settings → Developer settings → OAuth Apps
2. Authorization callback URL: `https://zig.cktech.org/api/v1/auth/github/callback`
3. Homepage URL: `https://zig.cktech.org`

## Deployment Steps

### 1. Clone and Prepare
```bash
# Clone repository
git clone https://github.com/cktech/zepplin.git /opt/zepplin
cd /opt/zepplin

# Copy your .env file
cp /path/to/.env .env

# Create required directories
mkdir -p backups logs
```

### 2. Configure Host Nginx
```bash
# Copy the nginx configuration
sudo cp nginx-host.conf /etc/nginx/sites-available/zepplin

# Update SSL certificate paths in the config (if different)
sudo nano /etc/nginx/sites-available/zepplin
# Update lines 31-32 with your actual cert paths

# Enable the site
sudo ln -s /etc/nginx/sites-available/zepplin /etc/nginx/sites-enabled/

# Test nginx configuration
sudo nginx -t

# Reload nginx
sudo systemctl reload nginx
```

### 3. Deploy with Docker Compose
```bash
# Build and start the container
docker compose up -d

# Check logs
docker compose logs -f zepplin-registry

# Verify health
curl http://localhost:8080/health
```

### 4. Verify SSO Integration
1. Navigate to https://zig.cktech.org
2. Test Azure AD login: Click "Login with Microsoft"
3. Test GitHub login: Click "Login with GitHub"
4. Verify user creation in logs

## Post-Deployment

### Database Backup Schedule
```bash
# Add to crontab for daily backups
0 2 * * * cd /opt/zepplin && docker compose exec zepplin-registry sqlite3 /app/data/zepplin.db ".backup /app/backups/zepplin-$(date +\%Y\%m\%d).db"
```

### Monitoring
```bash
# Check container status
docker compose ps

# View logs
docker compose logs -f zepplin-registry

# Check disk usage
docker system df
du -sh /opt/zepplin/backups/
```

### SSL Certificate Renewal
Since you're using Let's Encrypt on the host:
```bash
# Certificates should auto-renew via certbot
# Manual check:
sudo certbot renew --dry-run

# After renewal, reload nginx:
sudo systemctl reload nginx
```

## Maintenance Commands

### Update Zepplin
```bash
cd /opt/zepplin
git pull
docker compose build --no-cache
docker compose up -d
```

### Backup Database
```bash
# Manual backup
docker compose exec zepplin-registry sqlite3 /app/data/zepplin.db ".backup /app/backups/manual-$(date +%Y%m%d-%H%M%S).db"

# Copy backup to safe location
cp backups/manual-*.db /path/to/backup/storage/
```

### View Logs
```bash
# Application logs
docker compose logs -f zepplin-registry

# Nginx access logs
sudo tail -f /var/log/nginx/zepplin_access.log

# Nginx error logs
sudo tail -f /var/log/nginx/zepplin_error.log
```

### Restart Services
```bash
# Restart Zepplin only
docker compose restart zepplin-registry

# Full recreate (preserves data)
docker compose down && docker compose up -d
```

## Troubleshooting

### SSO Issues
1. Check environment variables are set correctly
2. Verify redirect URLs match exactly in Azure/GitHub
3. Check container logs for OAuth errors
4. Ensure `X-Forwarded-Proto: https` header is set in nginx

### Port Conflicts
If port 8080 is already in use:
```bash
# Check what's using port 8080
sudo lsof -i :8080

# Change port in docker-compose.yml if needed
# Update nginx-host.conf upstream accordingly
```

### Database Issues
```bash
# Access SQLite database
docker compose exec zepplin-registry sqlite3 /app/data/zepplin.db

# Check database integrity
.pragma integrity_check;

# View tables
.tables

# Exit
.quit
```

### Container Won't Start
```bash
# Check detailed logs
docker compose logs --tail=100 zepplin-registry

# Check file permissions
ls -la /opt/zepplin/

# Rebuild if needed
docker compose build --no-cache
docker compose up -d
```

## Security Notes

1. **Secrets**: Never commit `.env` file to git
2. **Firewall**: Ensure port 8080 is only accessible from localhost
3. **Updates**: Regularly update Docker images and host packages
4. **Backups**: Test restore procedures regularly
5. **Monitoring**: Set up alerts for disk space and container health

## Quick Health Check Script
```bash
#!/bin/bash
echo "=== Zepplin Health Check ==="
echo "Container Status:"
docker compose ps
echo ""
echo "Health Endpoint:"
curl -s http://localhost:8080/health | jq .
echo ""
echo "Nginx Status:"
sudo systemctl status nginx --no-pager | head -5
echo ""
echo "SSL Certificate:"
echo | openssl s_client -connect zig.cktech.org:443 2>/dev/null | openssl x509 -noout -dates
```

## Support

- Logs: `/opt/zepplin/logs/`
- Backups: `/opt/zepplin/backups/`
- Data: Docker volume `zepplin_data`
- Packages: Docker volume `zepplin_packages`