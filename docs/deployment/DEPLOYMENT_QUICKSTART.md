# Zepplin Registry Deployment Quickstart

Quick reference for deploying Zepplin Registry v0.5.1 with OAuth authentication to production.

## Prerequisites Checklist

- [ ] Domain configured (e.g., `zig.cktech.org`)
- [ ] SSL certificates ready
- [ ] Azure AD App Registration completed ([AZURE_SETUP.md](./AZURE_SETUP.md))
- [ ] GitHub OAuth App created (optional - [GITHUB_OAUTH_SETUP.md](./GITHUB_OAUTH_SETUP.md))
- [ ] Docker and Docker Compose installed

## Quick Setup

### 1. Clone and Configure
```bash
git clone <your-repo>
cd zepplin
cp .env.example .env
```

### 2. Update Environment Variables
Edit `.env` with your values:

```bash
# Domain Configuration
ZEPPLIN_DOMAIN=zig.cktech.org
REDIRECT_BASE_URL=https://zig.cktech.org

# Secrets (generate strong random values)
ZEPPLIN_SECRET_KEY=your-super-secret-key-here
JWT_SECRET=your-jwt-secret-here

# Azure AD Configuration
AZURE_TENANT_ID=your-tenant-id
AZURE_CLIENT_ID=your-client-id
AZURE_CLIENT_SECRET=your-client-secret

# GitHub OAuth (optional)
GITHUB_CLIENT_ID=your-github-client-id
GITHUB_CLIENT_SECRET=your-github-client-secret
```

### 3. SSL Certificates
Place your SSL certificates:
```bash
mkdir -p ssl
cp your-fullchain.pem ssl/fullchain.pem
cp your-privkey.pem ssl/privkey.pem
```

### 4. Deploy
```bash
docker-compose up -d
```

### 5. Verify
- Visit `https://zig.cktech.org`
- Test authentication: `https://zig.cktech.org/auth`
- Test publishing: `https://zig.cktech.org/publish`

## Key URLs

| Function | URL |
|----------|-----|
| **Registry Home** | `https://zig.cktech.org` |
| **Authentication** | `https://zig.cktech.org/auth` |
| **Package Publishing** | `https://zig.cktech.org/publish` |
| **API Packages** | `https://zig.cktech.org/api/packages` |
| **Health Check** | `https://zig.cktech.org/health` |

## OAuth Redirect URIs

Configure these in your OAuth apps:

- **Azure AD**: `https://zig.cktech.org/api/v1/auth/oidc/microsoft/callback`
- **GitHub**: `https://zig.cktech.org/api/v1/auth/oauth/github/callback`

## Monitoring Commands

```bash
# View logs
docker logs zepplin-registry -f
docker logs zepplin-nginx -f

# Check status
docker-compose ps

# Restart services
docker-compose restart

# Update deployment
docker-compose pull && docker-compose up -d
```

## Backup Important Data

```bash
# Backup database and packages
docker run --rm -v zepplin_data:/data -v $(pwd)/backup:/backup alpine tar czf /backup/zepplin-backup-$(date +%Y%m%d).tar.gz /data
```

---

**For detailed setup instructions, see:**
- [Azure AD Setup Guide](./AZURE_SETUP.md)
- [GitHub OAuth Setup Guide](./GITHUB_OAUTH_SETUP.md)