# Release & Deployment

Container build, orchestration, and reverse-proxy configuration for self-hosting
Zepplin. Run all commands from the **repo root** so the build context resolves
correctly.

## Contents

| File | Purpose |
|------|---------|
| `Dockerfile` | Multi-stage build (Bun frontend + Zig server → Debian runtime) |
| `Dockerfile.prebuilt` | Runtime image from a pre-built binary (no in-image compile) |
| `docker-compose.yml` | Service definition; build context is the repo root (`..`) |
| `.env.example` | Environment variable template — copy to `release/.env` |
| `nginx/production.conf` | Production reverse proxy (TLS, rate limiting, caching, SSO) |
| `nginx/example.conf` | Self-host template with placeholder domain and cert paths |
| `nginx/standalone.conf` | Full standalone `nginx.conf` (its own `http {}` block) |

## Quick start

```bash
# From the repo root:
cp release/.env.example release/.env      # then edit secrets/domain
docker compose -f release/docker-compose.yml up --build -d
docker compose -f release/docker-compose.yml logs -f
```

Compose auto-loads `release/.env` (the directory of the compose file). Keep your
real `.env` next to `docker-compose.yml`, not at the repo root.

## Build a one-off image

```bash
# Context must be the repo root so the Dockerfile can COPY src/, frontend/, assets/.
docker build -t zepplin -f release/Dockerfile .
```

## Reverse proxy

The container listens on `:8888` (host networking). Put one of the `nginx/`
configs in front of it:

- `production.conf` — copy to `/etc/nginx/sites-available/zepplin`, adjust
  `server_name` and the Let's Encrypt cert paths, then symlink into
  `sites-enabled/`.
- `example.conf` — start here for a new domain; replace
  `your-registry.example.com` and the cert paths.
- `standalone.conf` — use when running a dedicated nginx that owns the whole
  `nginx.conf`.

The domain Zepplin advertises in `sitemap.xml` / `robots.txt` is resolved at
runtime from `REDIRECT_BASE_URL`, then `ZEPPLIN_DOMAIN`, then the request `Host`
header — so the same image works behind any domain without a rebuild.
