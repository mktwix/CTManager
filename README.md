# CTManager (Cloudflared Tunnel Manager)

![Version](https://img.shields.io/badge/version-0.8.0-blue.svg)
![Platform](https://img.shields.io/badge/platform-windows-lightgrey.svg)

A Flutter desktop application that manages Cloudflare Tunnel port forwarding, enabling tunnel-to-tunnel access without requiring Cloudflare WARP. Perfect for accessing services like RDP, SSH, and SMB shares between different networks using Cloudflare Tunnels.

## Features

- 🔄 Easy port forwarding management for Cloudflare Tunnels
- 🔍 Real-time port forwarding status monitoring
- 🖥️ **RDP Support** - Remote Desktop Protocol access through tunnels
- 🔐 **SSH Support** - Secure Shell access through tunnels
- 📁 **SMB Support** - SMB share mounting and access through tunnels
- 💾 Local configuration storage
- 🎨 Clean, intuitive user interface
- 📝 Detailed logging system

## Prerequisites

- Windows OS
- Cloudflare account with at least one configured tunnel
- Cloudflare Tunnel Token

## Installation

1. Download the latest release from the [Releases](https://github.com/mktwix/ctmanager/releases) page.

## Usage

1. Install and launch the application.
2. Add a new domain access entry:
   - Domain (example: `pc-b.example.com`)
   - Local Port (example: `3389` for RDP, `22` for SSH, `445` for SMB)
   - Protocol (RDP, SSH, SMB)
3. Press **Start** on the entry to create local forwarding.
4. Access your service:
   - **RDP**: use the Launch button (or `mstsc /v:localhost:<port>`)
   - **SSH**: use the Launch button (or `ssh root@localhost -p <port>`)
   - **SMB**: authenticate when prompted and open the mounted drive from Explorer
5. Use the built-in Logs panel to troubleshoot connection and mount issues.

## Connect 2 or More PCs

You can use CTManager as a simple hub to access multiple remote PCs through Cloudflare Tunnel.

### Example Topology

- **PC-A**: Your operator machine running CTManager
- **PC-B / PC-C / PC-D**: Remote machines exposing services through Cloudflare Tunnel hostnames

### Step-by-Step

1. On each remote PC, make sure the target service is running:
   - RDP (`3389`) or SSH (`22`) or SMB (`445`)
2. In Cloudflare Zero Trust, confirm each remote service has a reachable hostname:
   - Example: `pc-b.example.com`, `pc-c.example.com`, `pc-d.example.com`
3. On PC-A (CTManager), create one entry per target service:
   - Entry 1: `pc-b.example.com` + `3389` + RDP
   - Entry 2: `pc-c.example.com` + `22` + SSH
   - Entry 3: `pc-d.example.com` + `445` + SMB
4. Start each entry from the Domain Access list.
5. Connect:
   - RDP/SSH via Launch actions
   - SMB via mounted drive (with credential prompt or saved secure credentials)

### Tips for Multi-PC Stability

- Use unique local ports per entry.
- Keep CTManager running while sessions are active.
- For SMB, run CTManager as a standard user (not Administrator) for better drive visibility in Explorer.
- Use Export/Import to move configurations between machines.

## Recent Changes and Bug Fixes

- Added secure SMB credential storage using OS secure storage (`flutter_secure_storage`).
- Migrated old DB-stored SMB credentials to secure storage during DB upgrade.
- Improved SMB flow:
  - Admin-mode warning dialog before mounting
  - Better drive letter auto-select/manual selection handling
  - Safer rollback if mount fails after tunnel start
- Improved cloudflared connection tracking per `domain:port` to avoid duplicate/overlapping starts.
- Improved import/export behavior:
  - Duplicate domains are skipped on import
  - `is_running` is exported as `0` for portability
- Added token masking in logs to reduce accidental secret exposure.
- Improved startup/runtime reconciliation of running tunnel and SMB mount states.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

### Version 0.8.0
- Enhanced port forwarding management
- **RDP Support** - Remote Desktop Protocol access through tunnels
- **SSH Support** - Secure Shell access through tunnels  
- **SMB Support** - SMB share mounting and access through tunnels
- Improved status monitoring
- Advanced logging system
- Windows support
- Bug fixes and performance improvements
