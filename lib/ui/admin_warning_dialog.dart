import 'package:flutter/material.dart';

class AdminWarningDialog extends StatelessWidget {
  const AdminWarningDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Administrator Mode Detected'),
      content: const SingleChildScrollView(
        child: ListBody(
          children: <Widget>[
            Text('CTManager is running with administrator privileges.'),
            SizedBox(height: 10),
            Text('For SMB drive mounting to work correctly and be visible in File Explorer, it is recommended to run the application as a standard user.'),
            SizedBox(height: 10),
            Text('Please close the application and restart it without "Run as administrator".'),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          child: const Text('OK'),
          onPressed: () {
            Navigator.of(context).pop();
          },
        ),
      ],
    );
  }
}

