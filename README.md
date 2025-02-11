# CTManager (Cloudflared Tunnel Manager)

![Version](https://img.shields.io/badge/version-0.6.0-blue.svg)
![Platform](https://img.shields.io/badge/platform-windows-lightgrey.svg)

A Flutter desktop application that manages Cloudflare Tunnel port forwarding, enabling tunnel-to-tunnel access without requiring Cloudflare WARP. Perfect for accessing services like RDP or SSH between different networks using Cloudflare Tunnels.

## Features

- 🔄 Easy port forwarding management for Cloudflare Tunnels
- 🔍 Real-time port forwarding status monitoring
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

1. Install and launch the application
2. Add a new port forward by specifying:
   - Domain (e.g., your-tunnel.domain.com)
   - Local Port to forward
3. Use your port forwards through the intuitive interface

## License

This project is licensed under the MIT License - see the LICENSE file for details.

### Version 0.6.0
- Initial release
- Port forwarding management
- Status monitoring
- Logging system
- Windows support
