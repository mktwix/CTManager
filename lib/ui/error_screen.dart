import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class ErrorScreen extends StatelessWidget {
  final String errorMessage;
  final dynamic error;
  final StackTrace? stackTrace;

  const ErrorScreen({
    super.key,
    required this.errorMessage,
    required this.error,
    this.stackTrace,
  });

  @override
  Widget build(BuildContext context) {
    bool isVCRedistError = error.toString().contains('Visual C++ Runtime');

    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 600),
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.error_outline,
                  color: Colors.red,
                  size: 64,
                ),
                const SizedBox(height: 24),
                Text(
                  errorMessage,
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                if (isVCRedistError) ...[
                  const Text(
                    'This application requires the Microsoft Visual C++ Runtime to be installed.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: () async {
                      final url = Uri.parse(
                        'https://aka.ms/vs/17/release/vc_redist.x64.exe'
                      );
                      if (await canLaunchUrl(url)) {
                        await launchUrl(url);
                      }
                    },
                    child: const Text('Download VC++ Runtime'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () {
                      final url = Uri.parse(
                        'https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist'
                      );
                      launchUrl(url);
                    },
                    child: const Text('Learn More'),
                  ),
                ] else ...[
                  Text(
                    error.toString(),
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  if (stackTrace != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.grey[200],
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SingleChildScrollView(
                        child: Text(
                          stackTrace.toString(),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () {
                    // Restart the app
                    Navigator.pushNamedAndRemoveUntil(
                      context,
                      '/',
                      (route) => false,
                    );
                  },
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
} 