import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

class WatchdogService {
  static final WatchdogService _instance = WatchdogService._internal();
  factory WatchdogService() => _instance;
  WatchdogService._internal();

  Timer? _heartbeatTimer;
  Timer? _watchdogTimer;
  Timer? _persistentNotificationTimer;
  DateTime? _lastHeartbeat;
  bool _isRunning = false;
  bool _isForegroundService = false;
  Function? _onAppDead;
  
  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  
  // Persistent notification IDs
  static const int _persistentNotificationId = 1001;
  static const int _criticalAlertId = 1002;
  static const int _serviceStatusId = 1003;

  // Initialize watchdog
  Future<void> initialize({Function? onAppDead}) async {
    _onAppDead = onAppDead;
    await _initializeNotifications();
    await _initializeForegroundService();
    print('WatchdogService: Initialized with foreground service support');
  }

  // Initialize notifications with enhanced channels
  Future<void> _initializeNotifications() async {
    try {
      // Enhanced watchdog notification channel
      const androidWatchdogChannel = AndroidNotificationChannel(
        'watchdog_persistent',
        'PNP Watchdog Service',
        description: 'Critical app monitoring service - DO NOT DISABLE',
        importance: Importance.max,
        enableVibration: true,
        enableLights: true,
        ledColor: Color(0xFFFF6600),
        playSound: true,
        showBadge: true,
      );

      // Critical alerts channel
      const androidCriticalChannel = AndroidNotificationChannel(
        'watchdog_critical',
        'PNP Critical Alerts',
        description: 'Critical system alerts that require immediate attention',
        importance: Importance.max,
        enableVibration: true,
        enableLights: true,
        ledColor: Color(0xFFFF0000),
        playSound: true,
        sound: RawResourceAndroidNotificationSound('alarm_sound'),
        showBadge: true,
      );

      // Service status channel
      const androidStatusChannel = AndroidNotificationChannel(
        'watchdog_status',
        'PNP Service Status',
        description: 'Shows current monitoring service status',
        importance: Importance.high,
        enableVibration: false,
        playSound: false,
        showBadge: true,
      );

      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      
      const initSettings = InitializationSettings(
        android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: iosSettings,
      );
      
      await _notifications.initialize(initSettings);
      
      // Create notification channels for Android
      await _notifications
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(androidWatchdogChannel);
          
      await _notifications
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(androidCriticalChannel);
          
      await _notifications
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(androidStatusChannel);
      
      print('WatchdogService: Enhanced notifications initialized');
    } catch (e) {
      print('WatchdogService: Error initializing notifications: $e');
    }
  }

  // Initialize foreground service
  Future<void> _initializeForegroundService() async {
    try {
      final service = FlutterBackgroundService();
      final isRunning = await service.isRunning();
      
      if (!isRunning) {
        await service.startService();
        print('WatchdogService: Background service started for watchdog');
      }
      
      _isForegroundService = true;
    } catch (e) {
      print('WatchdogService: Error initializing foreground service: $e');
      _isForegroundService = false;
    }
  }

  // Start watchdog monitoring with persistent notifications
  void startWatchdog() {
    if (_isRunning) {
      print('WatchdogService: Already running');
      return;
    }

    _isRunning = true;
    _lastHeartbeat = DateTime.now();
    
    // Start persistent notification immediately
    _showPersistentNotification();
    
    // Send heartbeat every 5 minutes
    _heartbeatTimer = Timer.periodic(const Duration(minutes: 5), (timer) {
      _sendHeartbeat();
    });

    // Check for dead app every minute
    _watchdogTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      _checkAppHealth();
    });

    // Update persistent notification every 30 seconds to keep it fresh
    _persistentNotificationTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      _updatePersistentNotification();
    });

    print('WatchdogService: Started monitoring with persistent notifications');
  }

  // Stop watchdog
  void stopWatchdog() {
    _heartbeatTimer?.cancel();
    _watchdogTimer?.cancel();
    _persistentNotificationTimer?.cancel();
    _isRunning = false;
    
    // Remove persistent notification
    _notifications.cancel(_persistentNotificationId);
    
    print('WatchdogService: Stopped monitoring');
  }

  // Show persistent notification that's hard to dismiss
  Future<void> _showPersistentNotification() async {
    try {
      const androidDetails = AndroidNotificationDetails(
        'watchdog_persistent',
        'PNP Watchdog Service',
        channelDescription: 'Critical app monitoring service - DO NOT DISABLE',
        importance: Importance.max,
        priority: Priority.max,
        ongoing: true, // Makes notification persistent
        autoCancel: false, // Prevents auto-dismissal
        fullScreenIntent: true, // Shows even when device is locked
        category: AndroidNotificationCategory.service,
        visibility: NotificationVisibility.public,
        color: Color(0xFFFF6600),
        colorized: true,
        enableVibration: true,
        enableLights: true,
        ledColor: Color(0xFFFF6600),
        ledOnMs: 1000,
        ledOffMs: 500,
        playSound: true,
        showWhen: true,
        channelShowBadge: true,
        timeoutAfter: null, // Never timeout
        actions: [
          AndroidNotificationAction('restart', 'Restart Service'),
          AndroidNotificationAction('status', 'Show Status'),
        ],
      );

      const notificationDetails = NotificationDetails(
        android: androidDetails,
      );

      await _notifications.show(
        _persistentNotificationId,
        '🛡️ PNP Watchdog Active',
        'Critical monitoring service running • Tap for status',
        notificationDetails,
      );
      
      print('WatchdogService: Persistent notification displayed');
    } catch (e) {
      print('WatchdogService: Error showing persistent notification: $e');
    }
  }

  // Update persistent notification with current status
  Future<void> _updatePersistentNotification() async {
    if (!_isRunning) return;
    
    try {
      final uptime = _lastHeartbeat != null 
          ? DateTime.now().difference(_lastHeartbeat!).inMinutes 
          : 0;
      
      const androidDetails = AndroidNotificationDetails(
        'watchdog_persistent',
        'PNP Watchdog Service',
        channelDescription: 'Critical app monitoring service - DO NOT DISABLE',
        importance: Importance.max,
        priority: Priority.max,
        ongoing: true,
        autoCancel: false,
        fullScreenIntent: true,
        category: AndroidNotificationCategory.service,
        visibility: NotificationVisibility.public,
        color: Color(0xFFFF6600),
        colorized: true,
        enableVibration: true,
        enableLights: true,
        ledColor: Color(0xFFFF6600),
        ledOnMs: 1000,
        ledOffMs: 500,
        playSound: false, // Don't play sound on updates
        showWhen: true,
        channelShowBadge: true,
        timeoutAfter: null,
        actions: [
          AndroidNotificationAction('restart', 'Restart Service'),
          AndroidNotificationAction('status', 'Show Status'),
        ],
      );

      const notificationDetails = NotificationDetails(
        android: androidDetails,
      );

      await _notifications.show(
        _persistentNotificationId,
        '🛡️ PNP Watchdog Active',
        'Monitoring: ${uptime}min • Last heartbeat: ${_lastHeartbeat?.toString().substring(11, 16) ?? "Unknown"}',
        notificationDetails,
      );
    } catch (e) {
      print('WatchdogService: Error updating persistent notification: $e');
    }
  }

  // Send heartbeat signal
  void _sendHeartbeat() {
    _lastHeartbeat = DateTime.now();
    _saveHeartbeatToStorage();
    _updatePersistentNotification();
    print('WatchdogService: Heartbeat sent at ${_lastHeartbeat!.hour}:${_lastHeartbeat!.minute}');
  }

  // Save heartbeat to persistent storage
  Future<void> _saveHeartbeatToStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_heartbeat', _lastHeartbeat!.toIso8601String());
      await prefs.setBool('app_is_alive', true);
      await prefs.setString('watchdog_last_heartbeat', DateTime.now().toIso8601String());
    } catch (e) {
      print('WatchdogService: Error saving heartbeat: $e');
    }
  }

  // Check app health with enhanced detection
  void _checkAppHealth() {
    if (_lastHeartbeat == null) return;

    final now = DateTime.now();
    final timeSinceLastHeartbeat = now.difference(_lastHeartbeat!);
    
    // If no heartbeat for 10 minutes, show warning
    if (timeSinceLastHeartbeat.inMinutes >= 10 && timeSinceLastHeartbeat.inMinutes < 15) {
      _showWarningNotification(timeSinceLastHeartbeat.inMinutes);
    }
    
    // If no heartbeat for 15 minutes, consider app dead
    if (timeSinceLastHeartbeat.inMinutes >= 15) {
      print('WatchdogService: App appears to be dead! Last heartbeat: ${timeSinceLastHeartbeat.inMinutes} minutes ago');
      _handleAppDead();
    }
  }

  // Show warning notification before app is considered dead
  Future<void> _showWarningNotification(int minutesSinceHeartbeat) async {
    try {
      final androidDetails = AndroidNotificationDetails(
        'watchdog_critical',
        'PNP Critical Alerts',
        channelDescription: 'Critical system alerts that require immediate attention',
        importance: Importance.max,
        ongoing: true,
        autoCancel: false,
        fullScreenIntent: true,
        category: AndroidNotificationCategory.alarm,
        visibility: NotificationVisibility.public,
        color: Color(0xFFFFA500),
        colorized: true,
        enableVibration: true,
        vibrationPattern: Int64List.fromList([0, 1000, 500, 1000]),
        enableLights: true,
        ledColor: Color(0xFFFFA500),
        ledOnMs: 1000,
        ledOffMs: 500,
        playSound: true,
        showWhen: true,
        timeoutAfter: null,
      );

      final notificationDetails = NotificationDetails(
        android: androidDetails,
      );

      await _notifications.show(
        _criticalAlertId,
        '⚠️ PNP Watchdog Warning',
        'No heartbeat for $minutesSinceHeartbeat minutes. App may be compromised.',
        notificationDetails,
      );
      
      print('WatchdogService: Warning notification sent');
    } catch (e) {
      print('WatchdogService: Error showing warning notification: $e');
    }
  }

  // Handle dead app with enhanced recovery
  Future<void> _handleAppDead() async {
    try {
      await _showAppDeadNotification();
      await _markAppAsDead();
      
      // Show critical alert that's impossible to miss
      await _showCriticalAppDeadAlert();
      
      // Try to restart or notify callback
      if (_onAppDead != null) {
        _onAppDead!();
      }
      
    } catch (e) {
      print('WatchdogService: Error handling dead app: $e');
    }
  }

  // Show notification that app is dead
  Future<void> _showAppDeadNotification() async {
    try {
      final androidDetails = AndroidNotificationDetails(
        'watchdog_critical',
        'PNP Critical Alerts',
        channelDescription: 'Critical system alerts that require immediate attention',
        importance: Importance.max,
        ongoing: true,
        autoCancel: false,
        fullScreenIntent: true,
        category: AndroidNotificationCategory.alarm,
        visibility: NotificationVisibility.public,
        color: Color(0xFFFF0000),
        colorized: true,
        enableVibration: true,
        vibrationPattern: Int64List.fromList([0, 1000, 500, 1000, 500, 1000]),
        enableLights: true,
        ledColor: Color(0xFFFF0000),
        ledOnMs: 1000,
        ledOffMs: 500,
        playSound: true,
        sound: RawResourceAndroidNotificationSound('alarm_sound'),
        showWhen: true,
        timeoutAfter: null,
      );

      final notificationDetails = NotificationDetails(
        android: androidDetails,
      );

      await _notifications.show(
        999, // Unique ID for watchdog notifications
        '🚨 PNP Device Monitor CRITICAL ALERT',
        'App monitoring stopped. Device tracking compromised. IMMEDIATE ACTION REQUIRED.',
        notificationDetails,
      );
      
      print('WatchdogService: Dead app notification sent');
    } catch (e) {
      print('WatchdogService: Error showing notification: $e');
    }
  }

  // Show critical alert that's impossible to miss
  Future<void> _showCriticalAppDeadAlert() async {
    try {
      final androidDetails = AndroidNotificationDetails(
        'watchdog_critical',
        'PNP Critical Alerts',
        channelDescription: 'Critical system alerts that require immediate attention',
        importance: Importance.max,
        ongoing: true,
        autoCancel: false,
        fullScreenIntent: true,
        category: AndroidNotificationCategory.alarm,
        visibility: NotificationVisibility.public,
        color: Color(0xFFFF0000),
        colorized: true,
        enableVibration: true,
        vibrationPattern: Int64List.fromList([0, 2000, 1000, 2000, 1000, 2000, 1000, 2000]),
        enableLights: true,
        ledColor: Color(0xFFFF0000),
        ledOnMs: 2000,
        ledOffMs: 1000,
        playSound: true,
        sound: RawResourceAndroidNotificationSound('alarm_sound'),
        showWhen: true,
        timeoutAfter: null,
        actions: [
          AndroidNotificationAction('restart', 'RESTART APP NOW'),
          AndroidNotificationAction('emergency', 'EMERGENCY MODE'),
        ],
      );

      final notificationDetails = NotificationDetails(
        android: androidDetails,
      );

      await _notifications.show(
        _serviceStatusId,
        '🆘 CRITICAL: PNP Monitoring COMPROMISED',
        'Device tracking STOPPED. Security breach detected. RESTART APP IMMEDIATELY.',
        notificationDetails,
      );
      
      print('WatchdogService: Critical app dead alert sent');
    } catch (e) {
      print('WatchdogService: Error showing critical alert: $e');
    }
  }

  // Mark app as dead in storage
  Future<void> _markAppAsDead() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('app_is_alive', false);
      await prefs.setString('app_died_at', DateTime.now().toIso8601String());
      await prefs.setBool('watchdog_alert_sent', true);
    } catch (e) {
      print('WatchdogService: Error marking app as dead: $e');
    }
  }

  // Check if app was previously dead
  Future<bool> wasAppDead() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final wasAlive = prefs.getBool('app_is_alive') ?? true;
      return !wasAlive;
    } catch (e) {
      print('WatchdogService: Error checking if app was dead: $e');
      return false;
    }
  }

  // Mark app as alive (call this when app starts)
  Future<void> markAppAsAlive() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('app_is_alive', true);
      await prefs.setString('app_started_at', DateTime.now().toIso8601String());
      await prefs.setBool('watchdog_alert_sent', false);
      _lastHeartbeat = DateTime.now();
      print('WatchdogService: App marked as alive');
    } catch (e) {
      print('WatchdogService: Error marking app as alive: $e');
    }
  }

  // Get watchdog status with enhanced information
  Map<String, dynamic> getStatus() {
    return {
      'isRunning': _isRunning,
      'isForegroundService': _isForegroundService,
      'lastHeartbeat': _lastHeartbeat?.toIso8601String(),
      'minutesSinceLastHeartbeat': _lastHeartbeat != null 
        ? DateTime.now().difference(_lastHeartbeat!).inMinutes 
        : null,
      'persistentNotificationActive': _isRunning,
      'serviceHealth': _getServiceHealthStatus(),
    };
  }

  // Get service health status
  String _getServiceHealthStatus() {
    if (!_isRunning) return 'STOPPED';
    if (_lastHeartbeat == null) return 'INITIALIZING';
    
    final minutesSinceHeartbeat = DateTime.now().difference(_lastHeartbeat!).inMinutes;
    if (minutesSinceHeartbeat < 5) return 'HEALTHY';
    if (minutesSinceHeartbeat < 10) return 'WARNING';
    if (minutesSinceHeartbeat < 15) return 'CRITICAL';
    return 'DEAD';
  }

  // Force heartbeat (call this from main app periodically)
  void ping() {
    _sendHeartbeat();
  }

  // Restart watchdog service
  Future<void> restartWatchdog() async {
    print('WatchdogService: Restarting watchdog service...');
    stopWatchdog();
    await Future.delayed(const Duration(seconds: 2));
    startWatchdog();
  }

  // Check if watchdog is healthy
  bool isHealthy() {
    if (!_isRunning || _lastHeartbeat == null) return false;
    final minutesSinceHeartbeat = DateTime.now().difference(_lastHeartbeat!).inMinutes;
    return minutesSinceHeartbeat < 10;
  }

  void dispose() {
    stopWatchdog();
  }
}