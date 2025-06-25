# Proxmox LXC Setup for Zepplin Registry

This script automatically creates and configures a Proxmox LXC container with Zepplin package registry.

## Features

- ✅ **Auto-configures** Debian 12 or Ubuntu 24.04 LTS container
- ✅ **Docker + Docker Compose** for production deployment
- ✅ **Zig compiler** for building Zepplin from source
- ✅ **Systemd service** for automatic startup
- ✅ **Nginx reverse proxy** configuration
- ✅ **Firewall setup** with UFW
- ✅ **Management scripts** for easy operation

## Quick Start

### 1. Run on Proxmox Host

```bash
# Clone Zepplin repository
git clone https://github.com/ghostkellz/zepplin.git
cd zepplin

# Make script executable
chmod +x setup-lxc.sh

# Create Debian 12 container (ID 100)
./setup-lxc.sh debian 100 zepplin-registry

# Or create Ubuntu 24.04 container (ID 101)
./setup-lxc.sh ubuntu 101 zepplin-ubuntu
```

### 2. Access Your Registry

```bash
# The script will show you the container IP, e.g.:
# Direct access: http://192.168.1.100:8080
# With Nginx: http://192.168.1.100
```

## Management Commands

```bash
# Enter the container
pct enter 100

# Inside container - manage Zepplin service
/opt/zepplin/manage.sh start|stop|restart|status|logs

# Docker Compose deployment
/opt/zepplin/manage.sh docker-up
/opt/zepplin/manage.sh docker-down

# Update Zepplin
/opt/zepplin/manage.sh update
```

## Container Specifications

- **OS**: Debian 12 or Ubuntu 24.04 LTS
- **Resources**: 2 CPU cores, 2GB RAM, 20GB storage
- **Features**: Nesting enabled for Docker
- **Network**: DHCP with firewall enabled
- **Startup**: Auto-start on boot

## File Locations

```
/opt/zepplin/           # Zepplin source code and binaries
/var/lib/zepplin/       # Package data storage
/etc/systemd/system/    # Systemd service files
```

## Production Setup

For production deployment:

1. **DNS Configuration**: Point your domain to the container IP
2. **SSL Certificates**: Configure Let's Encrypt with nginx
3. **Backup Strategy**: Backup `/var/lib/zepplin/` regularly
4. **Monitoring**: Set up log monitoring and alerts

## Troubleshooting

```bash
# Check service status
systemctl status zepplin

# View logs
journalctl -u zepplin -f

# Test Docker
docker --version
docker-compose --version

# Check Zig installation
zig version
```

## Security Notes

- Container runs in unprivileged mode
- UFW firewall enabled with minimal ports
- Automatic security updates enabled
- Consider setting up fail2ban for additional protection
