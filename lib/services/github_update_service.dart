import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';

class GitHubUpdateService {
  static const String repoUrl = 'https://api.github.com/repos/rcc4adevteam/Project-Nexus/releases/latest';
  static const String fallbackUrl = 'https://github.com/rcc4adevteam/Project-Nexus/releases';
  
  /// Check for updates from GitHub releases
  static Future<UpdateCheckResult> checkForUpdates(String currentVersion) async {
    try {
      print('GitHubUpdateService: Checking for updates...');
      
      final response = await http.get(
        Uri.parse(repoUrl),
        headers: {
          'Accept': 'application/vnd.github.v3+json',
          'User-Agent': 'Project-Nexus-App',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final Map<String, dynamic> releaseData = json.decode(response.body);
        
        final String latestVersion = releaseData['tag_name'] ?? '';
        final String releaseName = releaseData['name'] ?? '';
        final String releaseBody = releaseData['body'] ?? 'No release notes available';
        final String publishedAt = releaseData['published_at'] ?? '';
        final bool prerelease = releaseData['prerelease'] ?? false;
        
        // Get the first APK asset
        final List<dynamic> assets = releaseData['assets'] ?? [];
        String? downloadUrl;
        int? fileSize;
        
        for (var asset in assets) {
          final String name = asset['name'] ?? '';
          if (name.toLowerCase().endsWith('.apk')) {
            downloadUrl = asset['browser_download_url'];
            fileSize = asset['size'];
            break;
          }
        }
        
        if (downloadUrl == null) {
          return UpdateCheckResult(
            hasUpdate: false,
            error: 'No APK file found in the latest release',
          );
        }
        
        // Compare versions
        final bool hasUpdate = _isNewerVersion(currentVersion, latestVersion);
        
        return UpdateCheckResult(
          hasUpdate: hasUpdate,
          latestVersion: latestVersion,
          currentVersion: currentVersion,
          downloadUrl: downloadUrl,
          fileSize: fileSize,
          releaseName: releaseName,
          releaseNotes: releaseBody,
          publishedAt: publishedAt,
          isPrerelease: prerelease,
        );
        
      } else {
        return UpdateCheckResult(
          hasUpdate: false,
          error: 'Failed to fetch release info (HTTP ${response.statusCode})',
        );
      }
    } catch (e) {
      print('GitHubUpdateService: Error checking for updates: $e');
      return UpdateCheckResult(
        hasUpdate: false,
        error: 'Network error: ${e.toString()}',
      );
    }
  }
  
  /// Download APK with progress tracking
  static Future<DownloadResult> downloadAPK({
    required String downloadUrl,
    required Function(double progress, int downloaded, int total, double speed) onProgress,
    String? fileName,
  }) async {
    try {
      print('GitHubUpdateService: Starting APK download...');
      
      // Request storage permission for Android 10 and below
      if (Platform.isAndroid) {
        await Permission.requestInstallPackages.request();
      }
      
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/${fileName ?? 'update.apk'}');
      
      final client = http.Client();
      final request = http.Request('GET', Uri.parse(downloadUrl));
      final streamedResponse = await client.send(request);
      
      if (streamedResponse.statusCode != 200) {
        client.close();
        return DownloadResult(
          success: false,
          error: 'Download failed (HTTP ${streamedResponse.statusCode})',
        );
      }
      
      final int totalBytes = streamedResponse.contentLength ?? 0;
      int downloadedBytes = 0;
      final DateTime startTime = DateTime.now();
      
      final sink = file.openWrite();
      
      await for (final chunk in streamedResponse.stream) {
        downloadedBytes += chunk.length;
        sink.add(chunk);
        
        // Calculate download speed
        final elapsed = DateTime.now().difference(startTime).inMilliseconds;
        final speed = elapsed > 0 ? ((downloadedBytes / elapsed) * 1000).toDouble() : 0.0; // bytes per second
        
        // Calculate progress
        final progress = totalBytes > 0 ? (downloadedBytes / totalBytes).toDouble() : 0.0;
        
        onProgress(progress, downloadedBytes, totalBytes, speed);
      }
      
      await sink.close();
      client.close();
      
      print('GitHubUpdateService: Download completed successfully');
      
      return DownloadResult(
        success: true,
        filePath: file.path,
        fileSize: downloadedBytes,
      );
      
    } catch (e) {
      print('GitHubUpdateService: Download error: $e');
      return DownloadResult(
        success: false,
        error: 'Download failed: ${e.toString()}',
      );
    }
  }
  
  /// Install APK using Android intent
  static Future<InstallResult> installAPK(String filePath) async {
    try {
      print('GitHubUpdateService: Installing APK...');
      
      // Check if install permission is granted
      final status = await Permission.requestInstallPackages.status;
      if (!status.isGranted) {
        final newStatus = await Permission.requestInstallPackages.request();
        if (!newStatus.isGranted) {
          return InstallResult(
            success: false,
            error: 'Install permission denied. Please enable "Install unknown apps" in Settings.',
            needsPermission: true,
          );
        }
      }
      
      // Use platform channel to install APK
      try {
        const platform = MethodChannel('flutter/install_apk');
        await platform.invokeMethod('installApk', {'filePath': filePath});
        
        // Schedule cleanup of the downloaded APK file after a delay
        _scheduleAPKCleanup(filePath);
        
        return InstallResult(success: true);
      } catch (e) {
        // Fallback to URL launcher
        final uri = Uri.file(filePath);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          
          // Schedule cleanup of the downloaded APK file after a delay
          _scheduleAPKCleanup(filePath);
          
          return InstallResult(success: true);
        } else {
          return InstallResult(
            success: false,
            error: 'No app available to install APK. Please install manually.',
          );
        }
      }
      
    } catch (e) {
      print('GitHubUpdateService: Install error: $e');
      return InstallResult(
        success: false,
        error: 'Installation failed: ${e.toString()}',
      );
    }
  }
  
  /// Schedule cleanup of downloaded APK file
  static void _scheduleAPKCleanup(String filePath) {
    // Wait for installation to complete, then clean up
    Timer(const Duration(seconds: 30), () async {
      try {
        final file = File(filePath);
        if (await file.exists()) {
          await file.delete();
          print('GitHubUpdateService: Cleaned up downloaded APK: $filePath');
        }
      } catch (e) {
        print('GitHubUpdateService: Error cleaning up APK file: $e');
      }
    });
  }
  
  /// Clean up all temporary APK files
  static Future<void> cleanupTempAPKs() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final dir = Directory(tempDir.path);
      
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.toLowerCase().endsWith('.apk')) {
          try {
            await entity.delete();
            print('GitHubUpdateService: Cleaned up temp APK: ${entity.path}');
          } catch (e) {
            print('GitHubUpdateService: Error deleting temp APK ${entity.path}: $e');
          }
        }
      }
    } catch (e) {
      print('GitHubUpdateService: Error during temp APK cleanup: $e');
    }
  }
  
  /// Open GitHub releases page in browser
  static Future<bool> openReleasesPage() async {
    try {
      final uri = Uri.parse(fallbackUrl);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return true;
      }
      return false;
    } catch (e) {
      print('GitHubUpdateService: Error opening releases page: $e');
      return false;
    }
  }
  
  /// Compare version strings (simple semantic versioning)
  static bool _isNewerVersion(String currentVersion, String latestVersion) {
    // Remove 'v' prefix if present
    final current = currentVersion.replaceFirst('v', '');
    final latest = latestVersion.replaceFirst('v', '');
    
    final currentParts = current.split('.').map(int.tryParse).where((v) => v != null).cast<int>().toList();
    final latestParts = latest.split('.').map(int.tryParse).where((v) => v != null).cast<int>().toList();
    
    // Pad arrays to same length
    while (currentParts.length < latestParts.length) currentParts.add(0);
    while (latestParts.length < currentParts.length) latestParts.add(0);
    
    for (int i = 0; i < currentParts.length; i++) {
      if (latestParts[i] > currentParts[i]) return true;
      if (latestParts[i] < currentParts[i]) return false;
    }
    
    return false;
  }
  
  /// Format file size for display
  static String formatFileSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }
  
  /// Format download speed for display
  static String formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond < 1024) return '${bytesPerSecond.toStringAsFixed(0)}B/s';
    if (bytesPerSecond < 1024 * 1024) return '${(bytesPerSecond / 1024).toStringAsFixed(1)}KB/s';
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)}MB/s';
  }
}

/// Result classes for better error handling
class UpdateCheckResult {
  final bool hasUpdate;
  final String? latestVersion;
  final String? currentVersion;
  final String? downloadUrl;
  final int? fileSize;
  final String? releaseName;
  final String? releaseNotes;
  final String? publishedAt;
  final bool? isPrerelease;
  final String? error;

  UpdateCheckResult({
    required this.hasUpdate,
    this.latestVersion,
    this.currentVersion,
    this.downloadUrl,
    this.fileSize,
    this.releaseName,
    this.releaseNotes,
    this.publishedAt,
    this.isPrerelease,
    this.error,
  });
}

class DownloadResult {
  final bool success;
  final String? filePath;
  final int? fileSize;
  final String? error;

  DownloadResult({
    required this.success,
    this.filePath,
    this.fileSize,
    this.error,
  });
}

class InstallResult {
  final bool success;
  final String? error;
  final bool needsPermission;

  InstallResult({
    required this.success,
    this.error,
    this.needsPermission = false,
  });
}