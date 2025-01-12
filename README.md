# CTManager (Client Traffic Manager)

A middleware system that integrates FOSSBilling with Hiddify to automate VPN/proxy service account management.

## 🚀 Features

- **Automated License Management**: Synchronizes FOSSBilling licenses with Hiddify user accounts
- **Real-time Updates**: Monitors and processes license changes (new purchases, renewals, upgrades)
- **Secure Integration**: Uses secure API communication and database operations
- **Error Handling**: Comprehensive error catching and logging system

## 🛠️ Technical Architecture

### Core Components

1. **DatabasePoller**
   - Monitors FOSSBilling database for license changes
   - Processes new and updated licenses
   - Maintains synchronization between systems

2. **LicenseManager**
   - Handles license processing logic
   - Generates unique UUIDs for users
   - Calculates service durations

3. **HiddifyAPI**
   - Manages communication with Hiddify service
   - Handles user account creation and updates
   - Implements API error handling

## 📋 Prerequisites

- PHP 7.4 or higher
- MySQL/MariaDB
- FOSSBilling installation
- Hiddify server setup
- Valid API credentials for both services

## ⚙️ Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/ctmanager.git
   ```

2. Install dependencies:
   ```bash
   composer install
   ```

3. Configure your environment:
   - Copy `.env.example` to `.env`
   - Update database credentials
   - Add API keys and endpoints

4. Set up the database:
   ```bash
   php migrations/migrate.php
   ```

## 🔧 Configuration

1. FOSSBilling Configuration:
   - API endpoint
   - Authentication credentials
   - Database connection details

2. Hiddify Configuration:
   - API endpoint
   - Authentication token
   - Service parameters

## 🔍 Monitoring

The system includes logging for:
- License processing events
- API communication
- Error tracking
- User account modifications

## 🤝 Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 📞 Support

For support, please:
1. Check the [Issues](https://github.com/yourusername/ctmanager/issues) page
2. Create a new issue if your problem isn't already listed
3. Provide detailed information about your setup and the issue

## ✨ Acknowledgments

- FOSSBilling team for their billing system
- Hiddify team for their VPN/proxy service
- Contributors and testers
