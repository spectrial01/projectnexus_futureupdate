import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../utils/constants.dart';
import 'secure_storage_service.dart';
import 'error_handling_service.dart';
import 'loading_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
// Removed install_plugin import - will use url_launcher instead
import 'package:flutter/services.dart';

class ApiService {
  static Future<ApiResponse> login(String token, String deploymentCode) async {
    final url = Uri.parse('${AppConstants.baseUrl}setUnit');
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
    final body = json.encode({
      'deploymentCode': deploymentCode,
      'action': 'login',
      'timestamp': DateTime.now().toIso8601String(),
      'deviceInfo': await _getDeviceInfo(),
    });

    try {
      final response = await http.post(url, headers: headers, body: body);
      return ApiResponse.fromResponse(response);
    } catch (e) {
      return ApiResponse.error(ErrorHandlingService.getUserFriendlyError(e));
    }
  }

  // Download APK to cache and trigger installer (Android only)
  static Future<ApiResponse> downloadAndInstallApk(String apkUrl, {String fileName = 'update.apk'}) async {
    try {
      final sanitized = _ensureUrlHasScheme(apkUrl);
      final uri = Uri.parse(sanitized);

      final tempDir = await getTemporaryDirectory();
      final filePath = '${tempDir.path}/$fileName';
      final file = File(filePath);

      final request = await HttpClient().getUrl(uri);
      final response = await request.close();

      if (response.statusCode != 200) {
        return ApiResponse.error('Download failed (HTTP ${response.statusCode})');
      }

      final sink = file.openWrite();
      await response.forEach((chunk) => sink.add(chunk));
      await sink.close();

      // Open APK file with system handler
      try {
        final fileUri = Uri.file(filePath);
        if (await canLaunchUrl(fileUri)) {
          await launchUrl(fileUri, mode: LaunchMode.externalApplication);
          return ApiResponse(success: true, message: 'APK opened with system handler');
        } else {
          return ApiResponse.error('No app available to handle APK files');
        }
      } catch (e) {
        return ApiResponse.error('Failed to open APK: $e');
      }
    } catch (e) {
      return ApiResponse.error('Download error: $e');
    }
  }

  // UPDATE: Check for app updates via external PHP endpoint
  static Future<UpdateCheckResponse> checkAppUpdate({
    required String currentVersion,
    String platform = 'android',
  }) async {
    final headers = {
      'Content-Type': 'application/json',
    };
    final body = json.encode({
      'currentVersion': currentVersion,
      'platform': platform,
      'timestamp': DateTime.now().toIso8601String(),
    });

    // Try primary URL, then variants (with/without .php, and under /api/)
    final Uri base = Uri.parse(AppConstants.updateCheckUrl);
    final String lastSegment = base.pathSegments.isNotEmpty ? base.pathSegments.last : '';
    final String pathWithoutLast = base.pathSegments.length > 1
        ? '/${base.pathSegments.sublist(0, base.pathSegments.length - 1).join('/')}'
        : '';

    String ensureNoPhp(String s) => s.replaceAll(RegExp(r'\.php$'), '');

    final List<String> candidateUrls = [
      base.toString(),
      base.toString().endsWith('.php') ? ensureNoPhp(base.toString()) : '${base.toString()}.php',
      // /api/ variants
      Uri(
        scheme: base.scheme,
        host: base.host,
        port: base.hasPort ? base.port : null,
        path: '${pathWithoutLast}/api/${lastSegment}'.replaceAll('//', '/'),
      ).toString(),
      Uri(
        scheme: base.scheme,
        host: base.host,
        port: base.hasPort ? base.port : null,
        path: '${pathWithoutLast}/api/${ensureNoPhp(lastSegment)}.php'.replaceAll('//', '/'),
      ).toString(),
    ];

    for (final urlString in candidateUrls.toSet()) {
      try {
        final url = Uri.parse(urlString);
        final response = await http
            .post(url, headers: headers, body: body)
            .timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          final data = json.decode(response.body) as Map<String, dynamic>;
          return UpdateCheckResponse.fromJson(data);
        }

        // If not 404, return the specific error; if 404, try next candidate
        if (response.statusCode != 404) {
          return UpdateCheckResponse(
            hasUpdate: false,
            message: 'Failed to check update (HTTP ${response.statusCode})',
          );
        }
      } on TimeoutException {
        return UpdateCheckResponse(
          hasUpdate: false,
          message: 'Update check timed out',
        );
      } catch (_) {
        // Try next candidate
      }
    }

    return UpdateCheckResponse(
      hasUpdate: false,
      message: 'Failed to check update (endpoint not found: ${candidateUrls.join(" or ")})',
    );
  }

  // Helper to launch URLs (e.g., APK download)
  static Future<bool> openUrl(String urlString) async {
    try {
      final sanitized = _ensureUrlHasScheme(urlString);
      final uri = Uri.parse(sanitized);

      // Try multiple launch modes for better compatibility
      if (await canLaunchUrl(uri)) {
        if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          return true;
        }
        if (await launchUrl(uri, mode: LaunchMode.platformDefault)) {
          return true;
        }
        if (await launchUrl(uri, mode: LaunchMode.inAppBrowserView)) {
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  static String _ensureUrlHasScheme(String url) {
    final trimmed = url.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    // Default to https if no scheme
    return 'https://$trimmed';
  }

  static Future<ApiResponse> logout(String token, String deploymentCode) async {
    final url = Uri.parse('${AppConstants.baseUrl}setUnit');
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
    final body = json.encode({
      'deploymentCode': deploymentCode,
      'action': 'logout',
      'timestamp': DateTime.now().toIso8601String(),
    });

    try {
      final response = await http.post(url, headers: headers, body: body);
      return ApiResponse.fromResponse(response);
    } catch (e) {
      return ApiResponse.error(ErrorHandlingService.getUserFriendlyError(e));
    }
  }

  // Enhanced checkStatus with timeout and better error handling
  static Future<ApiResponse> checkStatus(String token, String deploymentCode) async {
    final url = Uri.parse('${AppConstants.baseUrl}checkStatus');
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
    final body = json.encode({
      'deploymentCode': deploymentCode,
      'timestamp': DateTime.now().toIso8601String(),
    });

    try {
      final response = await http.post(
        url, 
        headers: headers, 
        body: body,
      ).timeout(const Duration(seconds: 8)); // Timeout for session checks
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return ApiResponse(
          success: true,
          message: 'Status checked successfully',
          data: data,
        );
      } else if (response.statusCode == 401) {
        return ApiResponse(
          success: false,
          message: 'Authentication failed - token may be invalid',
          data: {'isLoggedIn': false},
        );
      } else {
        return ApiResponse(
          success: false,
          message: 'Server error checking status',
          data: {'isLoggedIn': false},
        );
      }
    } on TimeoutException {
      return ApiResponse.error('Session check timed out');
    } catch (e) {
      return ApiResponse.error('Network error checking status: ${e.toString()}');
    }
  }

  // ENHANCED: updateLocation with aggressive sync support
  static Future<ApiResponse> updateLocation({
    required String token,
    required String deploymentCode,
    required Position position,
    required int batteryLevel,
    required String signalStrength,
    bool isAggressiveSync = false,
  }) async {
    final url = Uri.parse('${AppConstants.baseUrl}updateLocation');
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
      'X-Sync-Type': isAggressiveSync ? 'aggressive' : 'normal', // Custom header for aggressive sync
    };
    
    final body = json.encode({
      'deploymentCode': deploymentCode,
      'location': {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracy': position.accuracy,
        'altitude': position.altitude,
        'speed': position.speed,
        'heading': position.heading,
      },
      'batteryStatus': batteryLevel,
      'signal': signalStrength,
      'timestamp': DateTime.now().toIso8601String(),
      'syncType': isAggressiveSync ? 'aggressive' : 'normal',
      'deviceInfo': isAggressiveSync ? await _getDeviceInfo() : null,
    });

    try {
      final response = await http.post(
        url, 
        headers: headers, 
        body: body
      ).timeout(Duration(seconds: isAggressiveSync ? 15 : 10));
      
      // Handle session expired or logged out
      if (response.statusCode == 403) {
        return ApiResponse.error('Session expired. Please login again.');
      }
      
      final apiResponse = ApiResponse.fromResponse(response);
      
      if (apiResponse.success && isAggressiveSync) {
        print('ApiService: ✅ SYNC successful - device should show ONLINE');
      }
      
      return apiResponse;
    } catch (e) {
      return ApiResponse.error('Network error updating location: ${e.toString()}');
    }
  }

  // NEW: Send multiple aggressive sync updates
  static Future<List<ApiResponse>> sendAggressiveSyncBurst({
    required String token,
    required String deploymentCode,
    required Position position,
    int burstCount = 3,
  }) async {
    print('ApiService: Starting aggressive sync burst ($burstCount updates)...');
    
    List<ApiResponse> results = [];
    
    try {
      // Get current device info
      final batteryLevel = await _getBatteryLevel();
      final signalStrength = await _getSignalStrength();
      
      // Send multiple rapid updates
      for (int i = 0; i < burstCount; i++) {
        print('ApiService: Sending sync ${i + 1}/$burstCount...');
        
        final response = await updateLocation(
          token: token,
          deploymentCode: deploymentCode,
          position: position,
          batteryLevel: batteryLevel,
          signalStrength: signalStrength,
          isAggressiveSync: true,
        );
        
        results.add(response);
        
        print('ApiService: sync ${i + 1}/$burstCount: ${response.success ? "✅ SUCCESS" : "❌ FAILED"}');
        
        // Brief delay between requests (except for the last one)
        if (i < burstCount - 1) {
          await Future.delayed(Duration(milliseconds: 500));
        }
      }
      
      final successCount = results.where((r) => r.success).length;
      print('ApiService: sync burst completed - $successCount/$burstCount successful');
      
    } catch (e) {
      print('ApiService: Error in sync burst: $e');
      results.add(ApiResponse.error('sync burst failed: $e'));
    }
    
    return results;
  }

  // NEW: Send immediate online status update
  static Future<ApiResponse> sendImmediateOnlineStatus({
    required String token,
    required String deploymentCode,
    Position? position,
  }) async {
    print('ApiService: Sending immediate online status update...');
    
    try {
      // If no position provided, try to get a quick location fix
      Position? currentPosition = position;
      
      if (currentPosition == null) {
        try {
          currentPosition = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.medium,
            timeLimit: Duration(seconds: 5),
          );
        } catch (e) {
          print('ApiService: Could not get quick location for online status: $e');
          // Continue without location
        }
      }
      
      // If we have a position, send location update
      if (currentPosition != null) {
        final batteryLevel = await _getBatteryLevel();
        final signalStrength = await _getSignalStrength();
        
        return await updateLocation(
          token: token,
          deploymentCode: deploymentCode,
          position: currentPosition,
          batteryLevel: batteryLevel,
          signalStrength: signalStrength,
          isAggressiveSync: true,
        );
      } else {
        // Send a heartbeat-style update without location
        return await _sendHeartbeatUpdate(token, deploymentCode);
      }
      
    } catch (e) {
      print('ApiService: Error sending immediate online status: $e');
      return ApiResponse.error('Failed to send online status: $e');
    }
  }

  // NEW: Send heartbeat update without location
  static Future<ApiResponse> _sendHeartbeatUpdate(String token, String deploymentCode) async {
    final url = Uri.parse('${AppConstants.baseUrl}heartbeat'); // Assuming heartbeat endpoint exists
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
    final body = json.encode({
      'deploymentCode': deploymentCode,
      'status': 'online',
      'timestamp': DateTime.now().toIso8601String(),
      'batteryStatus': await _getBatteryLevel(),
      'signal': await _getSignalStrength(),
    });

    try {
      final response = await http.post(url, headers: headers, body: body);
      return ApiResponse.fromResponse(response);
    } catch (e) {
      return ApiResponse.error('Heartbeat update failed: ${e.toString()}');
    }
  }

  // Helper methods for device information
  static Future<String> _getDeviceInfo() async {
    try {
      return 'Mobile Device - ${DateTime.now().toIso8601String()}';
    } catch (e) {
      return 'Unknown Device';
    }
  }

  static Future<int> _getBatteryLevel() async {
    try {
      final battery = Battery();
      return await battery.batteryLevel;
    } catch (e) {
      return 100; // Default value
    }
  }

  static Future<String> _getSignalStrength() async {
    try {
      final connectivity = Connectivity();
      final result = await connectivity.checkConnectivity();
      
      switch (result) {
        case ConnectivityResult.wifi:
        case ConnectivityResult.ethernet:
          return 'strong';
        case ConnectivityResult.mobile:
          return 'moderate';
        case ConnectivityResult.bluetooth:
          return 'weak';
        default:
          return 'poor';
      }
    } catch (e) {
      return 'poor';
    }
  }
}

class UpdateCheckResponse {
  final bool hasUpdate;
  final String? message;
  final Map<String, dynamic>? updateInfo;

  UpdateCheckResponse({
    required this.hasUpdate,
    this.message,
    this.updateInfo,
  });

  factory UpdateCheckResponse.fromJson(Map<String, dynamic> json) {
    return UpdateCheckResponse(
      hasUpdate: json['hasUpdate'] == true,
      message: json['message'] as String?,
      updateInfo: json['updateInfo'] is Map<String, dynamic>
          ? (json['updateInfo'] as Map<String, dynamic>)
          : null,
    );
  }
}

class ApiResponse {
  final bool success;
  final String message;
  final Map<String, dynamic>? data;

  ApiResponse({
    required this.success,
    required this.message,
    this.data,
  });

  factory ApiResponse.fromResponse(http.Response response) {
    try {
      final body = json.decode(response.body);
      return ApiResponse(
        success: response.statusCode == 200 && (body['success'] ?? false),
        message: body['message'] ?? 'Request completed',
        data: body,
      );
    } catch (e) {
      return ApiResponse(
        success: false,
        message: 'Invalid response format from server',
      );
    }
  }

  factory ApiResponse.error(String message) {
    return ApiResponse(success: false, message: message);
  }
}