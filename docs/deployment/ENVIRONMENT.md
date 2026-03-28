# Environment Configuration

Zepplin supports configuration through environment variables for production deployments.

## Required Environment Variables (Production)

### ZEPPLIN_SECRET_KEY
**Required for production**
- **Purpose**: JWT token signing and encryption
- **Format**: String (minimum 32 characters)
- **Example**: `ZEPPLIN_SECRET_KEY="your-super-secure-secret-key-min-32-chars"`
- **Security**: Generate with `openssl rand -base64 32`

## Optional Environment Variables

### ZEPPLIN_PORT
- **Default**: Uses port from command line argument (8080)
- **Purpose**: Override server port
- **Example**: `ZEPPLIN_PORT=3000`

### ZEPPLIN_BIND_ADDRESS
- **Default**: `0.0.0.0`
- **Purpose**: Network interface to bind to
- **Example**: `ZEPPLIN_BIND_ADDRESS=127.0.0.1` (localhost only)

### ZEPPLIN_DB_PATH
- **Default**: `{data_dir}/zepplin.db`
- **Purpose**: SQLite database file location
- **Example**: `ZEPPLIN_DB_PATH=/var/lib/zepplin/registry.db`

### ZEPPLIN_STORAGE_PATH
- **Default**: Uses data directory from command line
- **Purpose**: Package storage directory
- **Example**: `ZEPPLIN_STORAGE_PATH=/var/lib/zepplin/packages`

### ZEPPLIN_ZIGISTRY_URL
- **Default**: Uses built-in Zigistry client
- **Purpose**: Custom Zigistry API endpoint
- **Example**: `ZEPPLIN_ZIGISTRY_URL=https://api.zigistry.dev`

## Docker Environment Example

```bash
# docker-compose.yml
version: '3.8'
services:
  zepplin:
    image: zepplin:latest
    ports:
      - "8080:8080"
    environment:
      - ZEPPLIN_SECRET_KEY=your-super-secure-secret-key-min-32-chars
      - ZEPPLIN_PORT=8080
      - ZEPPLIN_BIND_ADDRESS=0.0.0.0
      - ZEPPLIN_DB_PATH=/data/zepplin.db
      - ZEPPLIN_STORAGE_PATH=/data/packages
    volumes:
      - zepplin_data:/data
volumes:
  zepplin_data:
```

## Systemd Service Example

```bash
# /etc/systemd/system/zepplin.service
[Unit]
Description=Zepplin Package Registry
After=network.target

[Service]
Type=simple
User=zepplin
WorkingDirectory=/opt/zepplin
ExecStart=/opt/zepplin/zepplin server
Environment=ZEPPLIN_SECRET_KEY=your-super-secure-secret-key-min-32-chars
Environment=ZEPPLIN_PORT=8080
Environment=ZEPPLIN_DB_PATH=/var/lib/zepplin/registry.db
Environment=ZEPPLIN_STORAGE_PATH=/var/lib/zepplin/packages
Restart=always

[Install]
WantedBy=multi-user.target
```

## Security Best Practices

1. **Never use default secret key in production**
2. **Generate strong secret keys**: `openssl rand -base64 32`
3. **Restrict bind address**: Use `127.0.0.1` for localhost-only access
4. **Secure file permissions**: Protect database and storage directories
5. **Use HTTPS**: Deploy behind reverse proxy with SSL/TLS
6. **Regular backups**: Back up database and package storage

## Startup Logs

When Zepplin starts, it will show which configuration is being used:

```
🚀 Zepplin Registry Server starting on http://localhost:8080
📦 Ready to serve packages!
🔧 Configuration loaded from environment variables (if set)
🔑 Using secret key from environment
🗄️  Using database path from environment: /var/lib/zepplin/registry.db
📦 Using storage path from environment: /var/lib/zepplin/packages
⚠️  Using default secret key - set ZEPPLIN_SECRET_KEY for production!
```

## Testing Configuration

You can test your environment configuration:

```bash
# Set environment variables
export ZEPPLIN_SECRET_KEY="test-secret-key-for-development-only"
export ZEPPLIN_PORT=3000

# Start server
./zepplin server

# Verify configuration in startup logs
```