# CTManager (Cloudflared Tunnel Manager)

A Flutter desktop application for managing Cloudflare Tunnel (cloudflared) instances with a user-friendly interface.

## Features

- 🚇 Create and manage Cloudflare Tunnels
- 🔄 Monitor tunnel status in real-time
- 💾 Local SQLite database for tunnel configuration storage
- 🔧 Automatic cloudflared binary installation and management
- 🖥️ Cross-platform support (Windows, macOS, Linux)
- 🎨 Material Design UI
- 📝 Detailed logging system

## Prerequisites

- Flutter SDK (>=2.18.0)
- Dart SDK
- A Cloudflare account with Tunnels enabled

## Installation

1. Clone the repository:
```bash
git clone https://github.com/yourusername/ctmanager.git
cd ctmanager
```

2. Install dependencies:
```bash
flutter pub get
```

3. Run the application:
```bash
flutter run
```

## Project Structure

```
lib/
├── main.dart              # Application entry point
├── models/               # Data models
├── providers/            # State management
├── services/            # Business logic and external services
│   ├── cloudflared_service.dart    # Cloudflared interaction
│   ├── database_service.dart       # SQLite database operations
│   └── install_cloudflared.dart    # Cloudflared installation
└── ui/                  # User interface components
    ├── home_page.dart
    └── tunnel_form.dart
```

## Dependencies

- `provider`: State management
- `sqflite_common_ffi`: SQLite database
- `path_provider`: File system access
- `http`: Network requests
- `shared_preferences`: Local storage
- `logger`: Logging system

## Development

The application is built with Flutter and follows the Provider pattern for state management. It uses:

- SQLite for persistent storage
- Material Design for the user interface
- Platform-specific code for native functionality

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- Cloudflare for their excellent Tunnels service
- Flutter team for the amazing framework
- All contributors who participate in this project
