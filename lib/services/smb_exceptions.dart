/// Exception thrown when WinFsp is not installed
class WinFspNotInstalledException implements Exception {
  final String message;
  WinFspNotInstalledException(this.message);
  
  @override
  String toString() => message;
} 