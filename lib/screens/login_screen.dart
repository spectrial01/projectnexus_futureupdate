import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import '../services/intelligent_location_service.dart';
import '../services/api_service.dart';
import '../services/background_service.dart';
import '../services/watchdog_service.dart';
import '../services/authentication_service.dart';
import '../services/github_update_service.dart';
import '../utils/constants.dart';
import '../widgets/download_progress_dialog.dart';
import 'dashboard_screen.dart';
import 'location_screen.dart';

// QR Scanner Screen
class QRScannerScreen extends StatefulWidget {
  const QRScannerScreen({super.key});

  @override
  State<QRScannerScreen> createState() => _QRScannerScreenState();
}

class _QRScannerScreenState extends State<QRScannerScreen> {
  bool _isPopped = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan QR Code'),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close, color: Colors.white),
            label: const Text('Cancel', style: TextStyle(color: Colors.white)),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
          ),
        ],
      ),
      body: Container(
        color: Colors.black,
        child: Stack(
          children: [
            MobileScanner(
              onDetect: (capture) {
                if (_isPopped) return;

                final List<Barcode> barcodes = capture.barcodes;
                if (barcodes.isNotEmpty) {
                  final String? code = barcodes.first.rawValue;
                  if (code != null) {
                    _isPopped = true;
                    Navigator.pop(context, code);
                  }
                }
              },
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withOpacity(0.7),
                    ],
                  ),
                ),
                child: const Column(
                  children: [
                    Text(
                      'Position QR code within the frame',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Tap Cancel to go back',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _tokenController = TextEditingController();
  final _deploymentCodeController = TextEditingController();
  final _locationService = IntelligentLocationService();
  final _watchdogService = WatchdogService();
  final _authService = AuthenticationService();

  bool _isDeploymentCodeVisible = false;
  bool _isLoading = false;
  bool _isLocationChecking = false;
  String _appVersion = '';
  bool _hasStoredCredentials = false;
  bool _isTokenLocked = false;
  Timer? _deploymentCodeTimer;

  // GitHub Update functionality
  UpdateCheckResult? _updateCheckResult;
  bool _isCheckingUpdate = false;
  bool _hasUpdateAvailable = false;

  // ENHANCED: Track deployment code validation status
  bool _isDeploymentCodeInUse = false;
  bool _isCheckingDeploymentCode = false;
  bool _isDeploymentCodeValid = false;
  String _lastCheckedDeploymentCode = '';
  String _deploymentCodeStatus = '';

  @override
  void initState() {
    super.initState();
    _initializeScreen();
  }

  @override
  void dispose() {
    _deploymentCodeTimer?.cancel();
    _authService.dispose();
    super.dispose();
  }

  Future<void> _initializeScreen() async {
    await _getAppVersion();
    await _loadStoredCredentials();
    await _initializeWatchdog();
    await _checkForGitHubUpdates();
    
    // Clean up any leftover APK files from previous update attempts
    try {
      await GitHubUpdateService.cleanupTempAPKs();
    } catch (e) {
      print('LoginScreen: Error cleaning up temp APKs: $e');
    }
  }

  Future<void> _getAppVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _appVersion = packageInfo.version);
  }

  // NEW: GitHub Update Check
  Future<void> _checkForGitHubUpdates() async {
    setState(() => _isCheckingUpdate = true);
    
    try {
      final result = await GitHubUpdateService.checkForUpdates(_appVersion);
      
      if (mounted) {
        setState(() {
          _updateCheckResult = result;
          _hasUpdateAvailable = result.hasUpdate;
          _isCheckingUpdate = false;
        });

        if (result.hasUpdate) {
          print('LoginScreen: Update available - ${result.latestVersion}');
        }
      }
    } catch (e) {
      print('LoginScreen: Error checking for updates: $e');
      if (mounted) {
        setState(() => _isCheckingUpdate = false);
      }
    }
  }

  // NEW: Handle GitHub Update Download and Install
  Future<void> _handleGitHubUpdate() async {
    if (_updateCheckResult?.downloadUrl == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Update URL not available'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final fileName = 'Project-Nexus-${_updateCheckResult!.latestVersion}.apk';
    DownloadProgressController? controller;

    // Show download progress dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => DownloadProgressDialog(
        fileName: fileName,
        onCancel: () {
          Navigator.of(context).pop();
        },
        onControllerReady: (dialogController) {
          controller = dialogController;
        },
      ),
    );

    // Wait for controller to be ready
    while (controller == null) {
      await Future.delayed(const Duration(milliseconds: 10));
    }

    try {
      // Start download
      controller!.updateStatus('Starting download...');
      
      final downloadResult = await GitHubUpdateService.downloadAPK(
        downloadUrl: _updateCheckResult!.downloadUrl!,
        fileName: fileName,
        onProgress: (progress, downloaded, total, speed) {
          controller?.updateProgress(progress, downloaded, total, speed);
        },
      );

      if (downloadResult.success) {
        controller!.updateStatus('Download completed! Preparing installation...');
        
        // Wait a moment to show completion
        await Future.delayed(const Duration(seconds: 1));
        
        if (mounted) {
          Navigator.of(context).pop(); // Close progress dialog
        }

        // Attempt to install
        final installResult = await GitHubUpdateService.installAPK(downloadResult.filePath!);
        
        if (!mounted) return;

        if (installResult.success) {
          _showInstallationSuccessDialog();
        } else if (installResult.needsPermission) {
          _showInstallPermissionDialog();
        } else {
          _showInstallationErrorDialog(installResult.error!);
        }
      } else {
        if (mounted) {
          Navigator.of(context).pop(); // Close progress dialog
        }
        _showDownloadErrorDialog(downloadResult.error!);
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // Close progress dialog
      }
      _showDownloadErrorDialog(e.toString());
    }
  }

  void _showInstallationSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green[600], size: 28),
            const SizedBox(width: 12),
            const Expanded(child: Text('Installation Started')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'The APK installation has been triggered. Follow the on-screen prompts to complete the installation.',
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue[200]!),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.blue[600], size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'After installation, restart the app to use the new version.',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.blue[800],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showInstallPermissionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.security, color: Colors.orange[600], size: 28),
            const SizedBox(width: 12),
            const Expanded(child: Text('Permission Required')),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'To install the update, you need to enable "Install unknown apps" permission for this app.',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              'Steps:',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text(
              '1. Go to Settings > Apps > Project Nexus\n'
              '2. Enable "Install unknown apps"\n'
              '3. Return and try the update again',
              style: TextStyle(fontSize: 14),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              _handleGitHubUpdate(); // Retry
            },
            child: Text('Try Again'),
          ),
        ],
      ),
    );
  }

  void _showInstallationErrorDialog(String error) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.error, color: Colors.red[600], size: 28),
            const SizedBox(width: 12),
            const Expanded(child: Text('Installation Failed')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Failed to install the update automatically.',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 12),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red[200]!),
              ),
              child: Text(
                'Error: $error',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.red[800],
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              GitHubUpdateService.openReleasesPage();
            },
            child: Text('Download Manually'),
          ),
        ],
      ),
    );
  }

  void _showDownloadErrorDialog(String error) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.download, color: Colors.red[600], size: 28),
            const SizedBox(width: 12),
            const Expanded(child: Text('Download Failed')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Failed to download the update.',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 12),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red[200]!),
              ),
              child: Text(
                'Error: $error',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.red[800],
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              _handleGitHubUpdate(); // Retry
            },
            child: Text('Retry'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              GitHubUpdateService.openReleasesPage();
            },
            child: Text('Manual Download'),
          ),
        ],
      ),
    );
  }

  // NEW: Show update available dialog
  Future<void> _showUpdateAvailableDialog() async {
    if (_updateCheckResult == null) return;

    final result = _updateCheckResult!;
    final screenSize = MediaQuery.of(context).size;
    final isSmallScreen = screenSize.width < 400;
    
    return showDialog(
      context: context,
      builder: (context) => AlertDialog(
        constraints: BoxConstraints(
          maxWidth: screenSize.width * 0.95,
          maxHeight: screenSize.height * 0.8,
        ),
        title: Row(
          children: [
            Icon(
              Icons.system_update, 
              color: Colors.green[600], 
              size: isSmallScreen ? 24 : 28,
            ),
            SizedBox(width: isSmallScreen ? 8 : 12),
            Expanded(
              child: Text(
                'Update Available',
                style: TextStyle(fontSize: isSmallScreen ? 18 : 20),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(isSmallScreen ? 12 : 16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.green[50]!, Colors.green[100]!],
                  ),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.green[200]!),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.new_releases, color: Colors.green[700], size: isSmallScreen ? 18 : 20),
                        SizedBox(width: isSmallScreen ? 6 : 8),
                        Expanded(
                          child: Text(
                            result.releaseName ?? 'New Version',
                            style: TextStyle(
                              fontSize: isSmallScreen ? 16 : 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.green[800],
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        Text('Current: ', style: TextStyle(color: Colors.grey[600])),
                        Text('v${result.currentVersion}', style: TextStyle(fontWeight: FontWeight.w500)),
                        Icon(Icons.arrow_forward, color: Colors.green[600], size: isSmallScreen ? 14 : 16),
                        Text('Latest: ', style: TextStyle(color: Colors.grey[600])),
                        Text('v${result.latestVersion}', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green[700])),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(height: 16),
              
              if (result.fileSize != null) ...[
                Row(
                  children: [
                    Icon(Icons.file_download, color: Colors.blue[600], size: isSmallScreen ? 18 : 20),
                    SizedBox(width: isSmallScreen ? 6 : 8),
                    Expanded(
                      child: Text(
                        'Size: ${GitHubUpdateService.formatFileSize(result.fileSize!)}',
                        style: TextStyle(fontSize: isSmallScreen ? 14 : 16),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 8),
              ],
              
              if (result.publishedAt != null) ...[
                Row(
                  children: [
                    Icon(Icons.schedule, color: Colors.grey[600], size: isSmallScreen ? 18 : 20),
                    SizedBox(width: isSmallScreen ? 6 : 8),
                    Expanded(
                      child: Text(
                        'Released: ${_formatDate(result.publishedAt!)}',
                        style: TextStyle(fontSize: isSmallScreen ? 14 : 16),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 8),
              ],
              
              if (result.isPrerelease == true) ...[
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.orange[100],
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.orange[300]!),
                  ),
                  child: Text(
                    'PRE-RELEASE',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.orange[800],
                    ),
                  ),
                ),
                SizedBox(height: 12),
              ],
              
              Text(
                'Release Notes:',
                style: TextStyle(
                  fontSize: isSmallScreen ? 14 : 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(isSmallScreen ? 10 : 12),
                decoration: BoxDecoration(
                  color: Colors.grey[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey[200]!),
                ),
                child: Text(
                  result.releaseNotes ?? 'No release notes available',
                  style: TextStyle(
                    fontSize: isSmallScreen ? 12 : 14, 
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  'Later',
                  style: TextStyle(fontSize: isSmallScreen ? 14 : 16),
                ),
              ),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  GitHubUpdateService.openReleasesPage();
                },
                child: Text(
                  'View on GitHub',
                  style: TextStyle(fontSize: isSmallScreen ? 14 : 16),
                ),
              ),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  _handleGitHubUpdate();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green[600],
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.symmetric(
                    horizontal: isSmallScreen ? 12 : 16,
                    vertical: isSmallScreen ? 10 : 12,
                  ),
                ),
                icon: Icon(Icons.download, size: isSmallScreen ? 18 : 20),
                label: Text(
                  'Download & Install',
                  style: TextStyle(fontSize: isSmallScreen ? 14 : 16),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatDate(String dateString) {
    try {
      final date = DateTime.parse(dateString);
      return '${date.day}/${date.month}/${date.year}';
    } catch (e) {
      return dateString;
    }
  }

  Future<void> _loadStoredCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final storedToken = prefs.getString('token');
    final isTokenLocked = prefs.getBool('isTokenLocked') ?? false;

    if (storedToken != null && isTokenLocked) {
      if (mounted) {
        setState(() {
          _tokenController.text = storedToken;
          _hasStoredCredentials = true;
          _isTokenLocked = true;
        });
      }
    }
  }

  Future<void> _initializeWatchdog() async {
    await _watchdogService.initialize();
    await _watchdogService.markAppAsAlive();
    final wasAppDead = await _watchdogService.wasAppDead();
    if (wasAppDead && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('App monitoring was interrupted. Please login again.'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  Future<void> _uploadTokenFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt'],
        withData: true,
      );

      if (result != null && result.files.single.bytes != null) {
        final token = utf8.decode(result.files.single.bytes!);
        setState(() {
          _tokenController.text = token.trim();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Token loaded successfully from file.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to read file: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _scanQRCodeForToken() async {
    final scannedCode = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (context) => const QRScannerScreen()),
    );

    if (scannedCode != null && mounted) {
      final cleanedCode = _extractPlainTextFromQR(scannedCode);
      final parts = cleanedCode.split('|');
      if (parts.length == 2) {
        setState(() {
          _tokenController.text = parts[0].trim();
          _deploymentCodeController.text = parts[1].trim();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Token and Deployment Code loaded from QR.'),
            backgroundColor: Colors.green,
          ),
        );
        _onDeploymentCodeChanged(parts[1].trim());
      } else {
        setState(() {
          _tokenController.text = cleanedCode.trim();
          _deploymentCodeController.clear();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Token loaded from QR. Please enter Deployment Code.'),
            backgroundColor: Colors.blue,
          ),
        );
      }
    }
  }

  Future<void> _scanQRCodeForDeployment() async {
    final scannedCode = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (context) => const QRScannerScreen()),
    );

    if (scannedCode != null && mounted) {
      final cleanedCode = _extractPlainTextFromQR(scannedCode);
      setState(() {
        _deploymentCodeController.text = cleanedCode.trim();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Deployment Code loaded from QR.'),
          backgroundColor: Colors.blue,
        ),
      );
      _onDeploymentCodeChanged(cleanedCode.trim());
    }
  }

  String _extractPlainTextFromQR(String qrData) {
    String cleanedData = qrData;
    if (cleanedData.startsWith('TEXT:')) {
      cleanedData = cleanedData.substring(5);
    }
    cleanedData = cleanedData.trim();
    cleanedData = cleanedData.replaceAll(RegExp(r'[\r\n\t]'), '');
    cleanedData = cleanedData.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '');
    return cleanedData;
  }

  void _onDeploymentCodeChanged(String value) {
    _deploymentCodeTimer?.cancel();

    if (value.trim() != _lastCheckedDeploymentCode) {
      setState(() {
        _isDeploymentCodeInUse = false;
        _isDeploymentCodeValid = false;
        _lastCheckedDeploymentCode = '';
        _deploymentCodeStatus = '';
      });
      ScaffoldMessenger.of(context).clearSnackBars();
    }

    if (value.trim().isEmpty) {
      setState(() {
        _isDeploymentCodeValid = false;
        _deploymentCodeStatus = 'Deployment code required';
      });
      return;
    }

    if (value.trim().length < 3) {
      setState(() {
        _isDeploymentCodeValid = false;
        _deploymentCodeStatus = 'Code too short (minimum 3 characters)';
      });
      return;
    }

    _deploymentCodeTimer = Timer(const Duration(milliseconds: 1000), () {
      if (_deploymentCodeController.text.trim() == value.trim() &&
          value.trim().isNotEmpty &&
          _tokenController.text.trim().isNotEmpty) {
        _validateDeploymentCodeWithAPI(value.trim());
      }
    });
  }

  Future<void> _validateDeploymentCodeWithAPI(String deploymentCode) async {
    if (_tokenController.text.trim().isEmpty) return;

    setState(() {
      _isCheckingDeploymentCode = true;
      _deploymentCodeStatus = 'Validating deployment code...';
    });

    try {
      final checkResponse = await ApiService.checkStatus(
        _tokenController.text.trim(),
        deploymentCode,
      );

      if (checkResponse.success && checkResponse.data != null) {
        final isLoggedIn = checkResponse.data!['isLoggedIn'] ?? false;

        setState(() {
          _isDeploymentCodeInUse = isLoggedIn;
          _isDeploymentCodeValid = !isLoggedIn;
          _lastCheckedDeploymentCode = deploymentCode;

          if (isLoggedIn) {
            _deploymentCodeStatus = 'Code is in use on another device';
          } else {
            _deploymentCodeStatus = 'Code is available';
          }
        });

        if (isLoggedIn && mounted) {
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.block, color: Colors.white, size: 24),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Deployment Code In Use',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'This code is active on another device. Login disabled until you use a different code.',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              backgroundColor: Colors.red[700],
              duration: const Duration(days: 1),
              behavior: SnackBarBehavior.fixed,
              dismissDirection: DismissDirection.none,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).clearSnackBars();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    const Icon(Icons.check_circle, color: Colors.white, size: 20),
                    const SizedBox(width: 8),
                    const Text(
                      'Valid deployment code',
                      style: TextStyle(fontSize: 14),
                    ),
                  ],
                ),
                backgroundColor: Colors.green[700],
                duration: const Duration(seconds: 2),
              ),
            );
          }
        }
      } else {
        setState(() {
          _isDeploymentCodeValid = false;
          _deploymentCodeStatus = 'Unable to validate code';
        });
      }
    } catch (e) {
      print('Deployment code validation failed: $e');
      setState(() {
        _isDeploymentCodeValid = false;
        _deploymentCodeStatus = 'Validation failed - network error';
      });
    } finally {
      setState(() => _isCheckingDeploymentCode = false);
    }
  }

  bool get _canLogin {
    return _tokenController.text.trim().isNotEmpty &&
        _deploymentCodeController.text.trim().isNotEmpty &&
        _isDeploymentCodeValid &&
        !_isDeploymentCodeInUse &&
        !_isLoading &&
        !_isLocationChecking &&
        !_isCheckingDeploymentCode;
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;

    if (!_canLogin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please provide a valid deployment code that is not in use.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    if (_isLoading) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Login already in progress. Please wait...'),
          backgroundColor: Colors.blue,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final hasLocationAccess = await _checkLocationRequirements();
      if (!hasLocationAccess) {
        setState(() => _isLoading = false);
        _showLocationRequirementDialog();
        return;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
                const SizedBox(width: 16),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Authenticating...',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Please wait while we verify your credentials',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            backgroundColor: Colors.blue[800],
            duration: const Duration(seconds: 8),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }

      final authResult = await _authService.login(
        _tokenController.text.trim(),
        _deploymentCodeController.text.trim(),
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).clearSnackBars();

      if (authResult.isSuccess) {
        print('LoginScreen: Login successful (${authResult.isOffline ? "offline" : "online"}), starting sync...');

        final isOffline = authResult.isOffline;

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('token', _tokenController.text.trim());
        await prefs.setString('deploymentCode', _deploymentCodeController.text.trim());
        await prefs.setBool('isTokenLocked', true);

        await _startImmediateAggressiveSync();

        _startBackgroundServiceAfterLogin();
        _watchdogService.startWatchdog();

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.green, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isOffline
                        ? 'Login successful (offline mode) - sync will start when online'
                        : 'Login successful! sync started - device online',
                    style: const TextStyle(fontSize: 14),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            backgroundColor: isOffline ? Colors.orange[800] : Colors.green[800],
            duration: const Duration(seconds: 3),
          ),
        );

        await Future.delayed(const Duration(milliseconds: 1500));

        if (mounted) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(
              builder: (context) => DashboardScreen(
                token: _tokenController.text.trim(),
                deploymentCode: _deploymentCodeController.text.trim(),
              ),
            ),
            (route) => false,
          );
        }
      } else {
        print('LoginScreen: Login failed');
        String errorTitle = 'Login Failed';
        String errorMessage = authResult.errorMessage ?? 'Authentication failed. Please check your credentials and try again.';
        _showGenericLoginError(errorTitle, errorMessage);
      }
    } catch (e) {
      print('LoginScreen: Login error: $e');

      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error, color: Colors.red, size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Connection error',
                    style: TextStyle(fontSize: 14),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            backgroundColor: Colors.red[800],
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _startImmediateAggressiveSync() async {
    try {
      print('LoginScreen: Starting immediate sync...');

      final position = await _locationService.getCurrentPosition(
        accuracy: LocationAccuracy.bestForNavigation,
        timeout: const Duration(seconds: 10),
      );

      if (position != null) {
        print('LoginScreen: Got location, sending immediate sync...');

        final result = await ApiService.updateLocation(
          token: _tokenController.text.trim(),
          deploymentCode: _deploymentCodeController.text.trim(),
          position: position,
          batteryLevel: 100,
          signalStrength: 'strong',
        );

        if (result.success) {
          print('LoginScreen: Immediate sync successful - device should show as ONLINE');
        } else {
          print('LoginScreen: Immediate sync failed: ${result.message}');
        }

        for (int i = 0; i < 3; i++) {
          await Future.delayed(const Duration(seconds: 2));

          final rapidSync = await ApiService.updateLocation(
            token: _tokenController.text.trim(),
            deploymentCode: _deploymentCodeController.text.trim(),
            position: position,
            batteryLevel: 100,
            signalStrength: 'strong',
          );

          print('LoginScreen: Rapid sync ${i + 1}/3: ${rapidSync.success ? "✅" : "❌"}');
        }

      } else {
        print('LoginScreen: Could not get location for immediate sync');
        try {
          print('LoginScreen: Starting background service for immediate sync...');
          await startBackgroundServiceSafely();
        } catch (e) {
          print('LoginScreen: Error starting background service: $e');
        }
      }
    } catch (e) {
      print('LoginScreen: Error in immediate sync: $e');
    }
  }

  void _showGenericLoginError(String title, String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.error, color: Colors.red, size: 28),
            const SizedBox(width: 8),
            Expanded(child: Text(title)),
          ],
        ),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<bool> _checkLocationRequirements() async {
    setState(() => _isLocationChecking = true);
    final hasAccess = await _locationService.checkLocationRequirements();
    if (mounted) setState(() => _isLocationChecking = false);
    return hasAccess;
  }

  void _showLocationRequirementDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Location Required'),
        content: const Text('This app requires location access. Please enable it in your device settings.'),
        actions: [
          TextButton(
            child: const Text('OK'),
            onPressed: () {
              Navigator.pop(context);
              Navigator.push(context, MaterialPageRoute(builder: (context) => const LocationScreen()));
            },
          ),
        ],
      ),
    );
  }

  Future<void> _startBackgroundServiceAfterLogin() async {
    try {
      await startBackgroundServiceSafely();
    } catch (e) {
      print("Error starting background service: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final screenWidth = screenSize.width;
    final screenHeight = screenSize.height;
    final isTablet = screenWidth > 600;
    final isSmallScreen = screenHeight < 700;

    final logoHeight = isTablet ? 140.0 : (isSmallScreen ? 80.0 : 120.0);
    final horizontalPadding = screenWidth * 0.08;
    final titleFontSize = isTablet ? 32.0 : (isSmallScreen ? 20.0 : 24.0);
    final buttonHeight = isTablet ? 60.0 : (isSmallScreen ? 45.0 : 50.0);
    final buttonFontSize = isTablet ? 20.0 : (isSmallScreen ? 16.0 : 18.0);
    final iconSize = isTablet ? 28.0 : (isSmallScreen ? 20.0 : 24.0);
    final spacingLarge = isTablet ? 40.0 : (isSmallScreen ? 20.0 : 32.0);
    final spacingMedium = isTablet ? 30.0 : (isSmallScreen ? 16.0 : 24.0);
    final spacingSmall = isTablet ? 24.0 : (isSmallScreen ? 12.0 : 16.0);

    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            title: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                AppConstants.appTitle,
                style: TextStyle(fontSize: isTablet ? 22.0 : 18.0),
              ),
            ),
            actions: [
              // NEW: GitHub Update Button - Only show when update is available
              if (_hasUpdateAvailable && _updateCheckResult != null)
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  child: Stack(
                    children: [
                      IconButton(
                        tooltip: 'Update Available - v${_updateCheckResult!.latestVersion}',
                        onPressed: _isCheckingUpdate ? null : _showUpdateAvailableDialog,
                        icon: Icon(
                          Icons.system_update,
                          color: Colors.green[600],
                          size: 28,
                        ),
                      ),
                      // Red notification dot
                      Positioned(
                        right: 8,
                        top: 8,
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: Colors.red[600],
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              
              // Refresh update check button
              if (_isCheckingUpdate)
                Container(
                  margin: const EdgeInsets.only(right: 16),
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Theme.of(context).primaryColor,
                    ),
                  ),
                )
              else
                IconButton(
                  tooltip: 'Check for Updates',
                  onPressed: _checkForGitHubUpdates,
                  icon: const Icon(Icons.refresh),
                ),
            ],
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: EdgeInsets.symmetric(
                horizontal: horizontalPadding,
                vertical: 16.0,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: screenHeight - kToolbarHeight - MediaQuery.of(context).padding.top - 32,
                ),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // NEW: Update Available Banner (shown at top when update exists)
                      if (_hasUpdateAvailable && _updateCheckResult != null) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          margin: const EdgeInsets.only(bottom: 20),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Colors.green[100]!, Colors.green[50]!],
                            ),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.green[300]!),
                          ),
                          child: InkWell(
                            onTap: _showUpdateAvailableDialog,
                            borderRadius: BorderRadius.circular(12),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.green[200],
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    Icons.system_update,
                                    color: Colors.green[800],
                                    size: 24,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Update Available!',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.green[800],
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'v${_updateCheckResult!.latestVersion} is ready to download',
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: Colors.green[700],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  Icons.arrow_forward_ios,
                                  color: Colors.green[600],
                                  size: 16,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],

                      // Logo section with responsive sizing
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Image.asset(
                              'assets/images/pnp_logo.png',
                              height: logoHeight,
                              fit: BoxFit.contain,
                            ),
                          ),
                          SizedBox(width: screenWidth * 0.04),
                          Flexible(
                            child: Image.asset(
                              'assets/images/images.png',
                              height: logoHeight,
                              fit: BoxFit.contain,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: spacingMedium),

                      // Title with responsive font size
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          'Secure Access',
                          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                            fontSize: titleFontSize,
                          ),
                        ),
                      ),
                      SizedBox(height: spacingLarge),

                      // Token field with responsive icons
                      TextFormField(
                        controller: _tokenController,
                        readOnly: _isTokenLocked,
                        style: TextStyle(fontSize: isTablet ? 18.0 : 16.0),
                        decoration: InputDecoration(
                          labelText: 'Token',
                          labelStyle: TextStyle(fontSize: isTablet ? 18.0 : 16.0),
                          prefixIcon: Icon(Icons.vpn_key, size: iconSize),
                          suffixIcon: _isTokenLocked
                              ? Icon(Icons.lock, color: Colors.grey, size: iconSize)
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: Icon(Icons.upload_file, size: iconSize),
                                      onPressed: _uploadTokenFile,
                                      tooltip: 'Upload Token from .txt file',
                                    ),
                                    IconButton(
                                      icon: Icon(Icons.qr_code_scanner, size: iconSize),
                                      onPressed: _scanQRCodeForToken,
                                      tooltip: 'Scan QR Code',
                                    ),
                                  ],
                                ),
                          border: const OutlineInputBorder(),
                          fillColor: _isTokenLocked ? Colors.grey[200] : null,
                          filled: _isTokenLocked,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 16.0,
                            vertical: isTablet ? 20.0 : 16.0,
                          ),
                        ),
                        validator: (value) => value!.isEmpty ? 'Please enter a token' : null,
                      ),
                      SizedBox(height: spacingSmall),

                      // Enhanced deployment code field with validation UI
                      TextFormField(
                        controller: _deploymentCodeController,
                        obscureText: !_isDeploymentCodeVisible,
                        onChanged: _onDeploymentCodeChanged,
                        style: TextStyle(fontSize: isTablet ? 18.0 : 16.0),
                        decoration: InputDecoration(
                          labelText: 'Deployment Code',
                          labelStyle: TextStyle(fontSize: isTablet ? 18.0 : 16.0),
                          prefixIcon: Icon(
                            _isDeploymentCodeInUse
                                ? Icons.block
                                : (_isDeploymentCodeValid ? Icons.verified : Icons.shield),
                            size: iconSize,
                            color: _isDeploymentCodeInUse
                                ? Colors.red
                                : (_isDeploymentCodeValid ? Colors.green : null),
                          ),
                          suffixIcon: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_isCheckingDeploymentCode)
                                Container(
                                  width: 20,
                                  height: 20,
                                  margin: const EdgeInsets.only(right: 8),
                                  child: const CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                                  ),
                                ),
                              if (!_isCheckingDeploymentCode && _lastCheckedDeploymentCode.isNotEmpty)
                                Container(
                                  margin: const EdgeInsets.only(right: 8),
                                  child: Icon(
                                    _isDeploymentCodeInUse
                                        ? Icons.error
                                        : (_isDeploymentCodeValid ? Icons.check_circle : Icons.warning),
                                    color: _isDeploymentCodeInUse
                                        ? Colors.red
                                        : (_isDeploymentCodeValid ? Colors.green : Colors.orange),
                                    size: 20,
                                  ),
                                ),
                              IconButton(
                                icon: Icon(Icons.qr_code_scanner, size: iconSize),
                                onPressed: _scanQRCodeForDeployment,
                                tooltip: 'Scan Deployment Code',
                              ),
                              IconButton(
                                icon: Icon(
                                  _isDeploymentCodeVisible ? Icons.visibility : Icons.visibility_off,
                                  size: iconSize,
                                ),
                                onPressed: () => setState(() => _isDeploymentCodeVisible = !_isDeploymentCodeVisible),
                              ),
                            ],
                          ),
                          border: OutlineInputBorder(
                            borderSide: BorderSide(
                              color: _isDeploymentCodeInUse
                                  ? Colors.red
                                  : (_isDeploymentCodeValid ? Colors.green : Colors.grey),
                              width: (_isDeploymentCodeInUse || _isDeploymentCodeValid) ? 2.0 : 1.0,
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderSide: BorderSide(
                              color: _isDeploymentCodeInUse
                                  ? Colors.red
                                  : (_isDeploymentCodeValid ? Colors.green : Colors.grey),
                              width: (_isDeploymentCodeInUse || _isDeploymentCodeValid) ? 2.0 : 1.0,
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderSide: BorderSide(
                              color: _isDeploymentCodeInUse
                                  ? Colors.red
                                  : (_isDeploymentCodeValid ? Colors.green : Colors.blue),
                              width: 2.0,
                            ),
                          ),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 16.0,
                            vertical: isTablet ? 20.0 : 16.0,
                          ),
                          helperText: _deploymentCodeStatus.isNotEmpty ? _deploymentCodeStatus : null,
                          helperStyle: TextStyle(
                            color: _isDeploymentCodeInUse
                                ? Colors.red
                                : (_isDeploymentCodeValid ? Colors.green : Colors.orange),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        validator: (value) => value!.isEmpty ? 'Please enter a deployment code' : null,
                      ),
                      SizedBox(height: spacingMedium),

                      // Secure Login button with improved loading states
                      SizedBox(
                        width: double.infinity,
                        height: buttonHeight,
                        child: ElevatedButton(
                          onPressed: (_canLogin && !_isLoading && !_isLocationChecking && !_isCheckingDeploymentCode) ? _login : null,
                          style: ElevatedButton.styleFrom(
                            textStyle: TextStyle(
                              fontSize: buttonFontSize,
                              fontWeight: FontWeight.bold,
                            ),
                            backgroundColor: (_canLogin && !_isLoading && !_isLocationChecking && !_isCheckingDeploymentCode)
                                ? Theme.of(context).colorScheme.primary
                                : Colors.grey[400],
                            foregroundColor: (_canLogin && !_isLoading && !_isLocationChecking && !_isCheckingDeploymentCode)
                                ? Colors.white
                                : Colors.grey[600],
                            elevation: (_canLogin && !_isLoading && !_isLocationChecking && !_isCheckingDeploymentCode) ? 4.0 : 0.0,
                            disabledBackgroundColor: Colors.grey[400],
                            disabledForegroundColor: Colors.grey[600],
                          ),
                          child: _buildLoginButtonContent(),
                        ),
                      ),
                      SizedBox(height: spacingMedium),

                      // FAQ and Feedback buttons (non-functional)
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: null,
                              icon: Icon(Icons.help_outline, size: iconSize * 0.8),
                              label: Text(
                                'FAQ',
                                style: TextStyle(fontSize: buttonFontSize * 0.8),
                              ),
                              style: OutlinedButton.styleFrom(
                                padding: EdgeInsets.symmetric(vertical: buttonHeight * 0.3),
                                side: BorderSide(color: Colors.grey[400]!),
                                foregroundColor: Colors.grey[600],
                              ),
                            ),
                          ),
                          SizedBox(width: spacingSmall),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: null,
                              icon: Icon(Icons.feedback_outlined, size: iconSize * 0.8),
                              label: Text(
                                'Feedback',
                                style: TextStyle(fontSize: buttonFontSize * 0.8),
                              ),
                              style: OutlinedButton.styleFrom(
                                padding: EdgeInsets.symmetric(vertical: buttonHeight * 0.3),
                                side: BorderSide(color: Colors.grey[400]!),
                                foregroundColor: Colors.grey[600],
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: spacingSmall),

                      // Version text and status with responsive sizing
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Column(
                          children: [
                            Text(
                              'v$_appVersion • Real-time Session Monitoring • Aggressive Sync',
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: isTablet ? 16.0 : 14.0,
                              ),
                            ),
                            if (!_canLogin && _deploymentCodeController.text.trim().isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.orange.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.orange.withOpacity(0.3)),
                                ),
                                child: Text(
                                  _isCheckingDeploymentCode
                                      ? 'Validating deployment code...'
                                      : (_isDeploymentCodeInUse
                                      ? 'Login blocked - code in use'
                                      : 'Please wait for validation'),
                                  style: TextStyle(
                                    color: Colors.orange[700],
                                    fontSize: isTablet ? 14.0 : 12.0,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                            if (_hasUpdateAvailable && _updateCheckResult != null) ...[
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.green.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.green.withOpacity(0.3)),
                                ),
                                child: Text(
                                  'Update v${_updateCheckResult!.latestVersion} Available',
                                  style: TextStyle(
                                    color: Colors.green[700],
                                    fontSize: isTablet ? 14.0 : 12.0,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        
        // Loading overlay to prevent user interaction during login
        if (_isLoading)
          Container(
            color: Colors.black.withOpacity(0.7),
            child: Center(
              child: Container(
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 60,
                      height: 60,
                      child: CircularProgressIndicator(
                        strokeWidth: 4,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                      ),
                    ),
                    SizedBox(height: 24),
                    Text(
                      'Authenticating...',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Please wait while we verify your credentials',
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.grey,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Do not close the app',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.orange,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  // Helper method to build login button content with proper loading states
  Widget _buildLoginButtonContent() {
    if (_isLoading || _isLocationChecking || _isCheckingDeploymentCode) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              color: Colors.white,
              strokeWidth: 2,
            ),
          ),
          SizedBox(width: 12),
          Text(
            'Processing...',
            style: TextStyle(fontSize: 16),
          ),
        ],
      );
    } else if (!_canLogin) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock, size: 20, color: Colors.grey[600]),
          const SizedBox(width: 8),
          const Text(
            'Login Disabled',
            style: TextStyle(fontSize: 16),
          ),
        ],
      );
    } else {
      return const Text(
        'Secure Login',
        style: TextStyle(fontSize: 16),
      );
    }
  }
}