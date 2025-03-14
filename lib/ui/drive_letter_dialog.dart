import 'package:flutter/material.dart';
import '../services/smb_service.dart';

class DriveLetterDialog extends StatefulWidget {
  final String domain;

  const DriveLetterDialog({
    super.key,
    required this.domain,
  });

  @override
  State<DriveLetterDialog> createState() => _DriveLetterDialogState();
}

class _DriveLetterDialogState extends State<DriveLetterDialog> {
  final SmbService _smbService = SmbService();
  List<String> _availableDriveLetters = [];
  String? _selectedDriveLetter;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadAvailableDriveLetters();
  }

  Future<void> _loadAvailableDriveLetters() async {
    setState(() {
      _isLoading = true;
    });

    try {
      _availableDriveLetters = await _smbService.getAvailableDriveLetters();
      if (_availableDriveLetters.isNotEmpty) {
        _selectedDriveLetter = _availableDriveLetters.first;
      }
    } catch (e) {
      // Handle error
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Select Drive Letter'),
      content: _isLoading
          ? const SizedBox(
              height: 100,
              child: Center(
                child: CircularProgressIndicator(),
              ),
            )
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Choose a drive letter for ${widget.domain}.'),
                  const SizedBox(height: 16),
                  if (_availableDriveLetters.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    const Text('Available drive letters:'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _availableDriveLetters.map((letter) {
                        return ChoiceChip(
                          label: Text('$letter:'),
                          selected: _selectedDriveLetter == letter,
                          onSelected: (selected) {
                            if (selected) {
                              setState(() {
                                _selectedDriveLetter = letter;
                              });
                            }
                          },
                        );
                      }).toList(),
                    ),
                  ],
                  if (_availableDriveLetters.isEmpty && !_isLoading)
                    const Text(
                      'No drive letters available. Please free up a drive letter.',
                      style: TextStyle(color: Colors.red),
                    ),
                ],
              ),
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _availableDriveLetters.isEmpty
              ? null
              : () {
                  Navigator.of(context).pop(_selectedDriveLetter);
                },
          child: const Text('Confirm'),
        ),
      ],
    );
  }
} 