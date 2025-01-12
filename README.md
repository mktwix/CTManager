# CTManager

CTManager is a middleware system designed to integrate FOSSBilling with Hiddify, automating the process of managing VPN/proxy user accounts based on license purchases.

## 🚀 Features

- **Automated License Management**: Synchronizes FOSSBilling licenses with Hiddify user accounts
- **Real-time Updates**: Monitors and processes license changes automatically
- **Secure Integration**: Implements secure database operations and API interactions
- **Error Handling**: Comprehensive error catching and logging system

## 🛠️ Technical Architecture

### Core Components

1. **DatabasePoller**
   - Monitors FOSSBilling database for new/updated licenses
   - Processes unhandled license changes
   - Manages license status synchronization

2. **LicenseManager**
   - Creates and updates Hiddify user accounts
   - Handles UUID generation
   - Calculates license durations

3. **HiddifyAPI**
   - Manages Hiddify service integration
   - Handles user creation and updates
   - Processes API communications

## 📋 Prerequisites

- PHP 7.4 or higher
- MySQL/MariaDB
- FOSSBilling installation
- Hiddify server setup
- Composer (PHP package manager)

## 🔧 Installation

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
   - Set Hiddify API configuration

4. Set up the database:
   ```bash
   php migrations/migrate.php
   ```

## ⚙️ Configuration

1. FOSSBilling Connection:
   - Configure database credentials
   - Set up polling interval

2. Hiddify Integration:
   - Configure API endpoint
   - Set authentication details
   - Define default user settings

## 🔍 Monitoring and Logging

- Logs are stored in the `logs` directory
- Monitor system status through the admin interface
- Check error logs for troubleshooting

## 🤝 Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🆘 Support

For support and questions:
- Open an issue on GitHub
- Contact the development team
- Check the documentation

## 🔐 Security

- Uses prepared statements for database queries
- Implements secure API communication
- Follows security best practices

## 🗺️ Roadmap

- [ ] Add support for multiple Hiddify servers
- [ ] Implement advanced monitoring dashboard
- [ ] Add backup and restore functionality
- [ ] Enhance error reporting and notifications
