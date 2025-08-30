import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../services/intelligent_location_service.dart';
import '../services/device_service.dart';
import '../services/api_service.dart';
import '../services/background_service.dart';
import '../services/watchdog_service.dart';
import '../services/wake_lock_service.dart';
import '../services/theme_provider.dart';
import '../services/responsive_ui_service.dart';
import '../widgets/metric_card.dart';
import '../widgets/auto_size_text.dart';
import '../utils/constants.dart';
import 'login_screen.dart';

class DashboardScreen extends StatefulWidget {
  final String token;
  final String deploymentCode;

  const DashboardScreen({
    super.key,
    required this.token,
    required this.deploymentCode,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with ResponsiveStateMixin {
  final _locationService = IntelligentLocationService();
  final _deviceService = DeviceService();
  final _watchdogService = WatchdogService();
  final _wakeLockService = WakeLockService();
  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();

  Timer? _apiUpdateTimer;
  Timer? _heartbeatTimer;
  Timer? _statusUpdateTimer;
  Timer? _reconnectionTimer;
  Timer? _sessionVerificationTimer;

  bool _isLoading = true;
  bool _isLocationLoading = true;
  double _internetSpeed = 0.0;
  bool _hasInitialized = false;
  Map<String, dynamic> _watchdogStatus = {};
  Map<String, dynamic> _wakeLockStatus = {};
  Map<String, dynamic> _deviceStatus = {};
  StreamSubscription<ConnectivityResult>? _connectivitySubscription;
  int _locationUpdatesSent = 0;
  DateTime? _lastSuccessfulUpdate;
  bool _isOnline = true;
  bool _wasOfflineNotificationSent = false;

  bool _isCheckingSession = false;
  bool _sessionActive = true;
  DateTime? _lastSessionCheck;
  int _consecutiveSessionFailures = 0;
  static const int _maxSessionFailures = 3;
  static const Duration _sessionCheckTimeout = Duration(seconds: 8);
  static const Duration _sessionRetryDelay = Duration(seconds: 2);

  StreamSubscription<ServiceStatus>? _locationServiceStatusSubscription;
  bool _isLocationServiceEnabled = true;

  // --->>> NEW: Timer for looping notification alarm
  Timer? _locationAlarmTimer;
  // ---<<<

  @override
  void initState() {
    super.initState();
    _initializeServices();
    _initializeNotifications();
    _listenForConnectivityChanges();
    _startSessionMonitoring();
    _listenToLocationServiceStatus();
  }

  @override
  void dispose() {
    _cleanupAllTimers();
    _locationAlarmTimer?.cancel(); // --->>> NEW: Cancel the timer on dispose
    _locationService.dispose();
    _deviceService.dispose();
    _watchdogService.stopWatchdog();
    _connectivitySubscription?.cancel();
    _locationServiceStatusSubscription?.cancel();
    super.dispose();
  }

  void _listenToLocationServiceStatus() {
    _locationServiceStatusSubscription = Geolocator.getServiceStatusStream().listen((ServiceStatus status) {
      if (mounted) {
        final isEnabled = (status == ServiceStatus.enabled);

        if (_isLocationServiceEnabled != isEnabled) {
          setState(() {
            _isLocationServiceEnabled = isEnabled;
          });

          // --->>> MODIFIED: Control the notification-based alarm
          if (!isEnabled) {
            // Location is turned OFF, start the alarm
            _startLocationAlarm();
          } else {
            // Location is turned back ON, stop the alarm
            _stopLocationAlarm();
          }
          // ---<<<
        }
      }
    });
  }

  // --->>> NEW: Methods to control the notification alarm
  void _startLocationAlarm() {
    // Cancel any existing timer to avoid duplicates
    _locationAlarmTimer?.cancel();

    // Trigger the alarm immediately, then repeat every 5 seconds
    _showLocationOffNotification();
    _locationAlarmTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      _showLocationOffNotification();
    });
    print('Dashboard: Starting location disabled alarm via notifications.');
  }

  void _stopLocationAlarm() {
    _locationAlarmTimer?.cancel();
    _notifications.cancel(AppConstants.locationWarningNotificationId);
    print('Dashboard: Stopping location alarm and clearing notification.');
  }

  Future<void> _showLocationOffNotification() async {
    // This uses the sound from android/app/src/main/res/raw/alarm_sound.mp3
    const AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'location_alarm_channel', // A unique channel ID
      'Location Status',
      channelDescription: 'Alarm for when location service is disabled',
      importance: Importance.max,
      priority: Priority.high,
      sound: RawResourceAndroidNotificationSound('alarm_sound'), // Use the raw resource
      playSound: true,
      ongoing: true, // Makes the notification persistent
    );
    const NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);

    await _notifications.show(
      AppConstants.locationWarningNotificationId,
      'Location Service Disabled',
      'Location is required for the app to function correctly. Please turn it back on.',
      platformChannelSpecifics,
    );
  }
  // ---<<<

  void _cleanupAllTimers() {
    print('Dashboard: Cleaning up all timers...');
    _apiUpdateTimer?.cancel();
    _heartbeatTimer?.cancel();
    _statusUpdateTimer?.cancel();
    _reconnectionTimer?.cancel();
    _sessionVerificationTimer?.cancel();

    _apiUpdateTimer = null;
    _heartbeatTimer = null;
    _statusUpdateTimer = null;
    _reconnectionTimer = null;
    _sessionVerificationTimer = null;

    print('Dashboard: All timers cleaned up successfully');
  }

  void _startSessionMonitoring() {
    print('Dashboard: Starting enhanced session monitoring with timeout handling...');

    _sessionVerificationTimer?.cancel();

    _sessionVerificationTimer = Timer.periodic(
      const Duration(seconds: 45),
      (timer) => _verifySessionWithTimeout()
    );

    print('Dashboard: Enhanced session monitoring started - checking every 5 seconds with 8s timeout');
  }

  Future<void> _verifySessionWithTimeout() async {
    if (_isCheckingSession) {
      print('Dashboard: Session check already in progress, skipping...');
      return;
    }

    _isCheckingSession = true;
    _lastSessionCheck = DateTime.now();

    try {
      print('Dashboard: Starting session verification with timeout... (${_lastSessionCheck!.toString().substring(11, 19)})');

      final sessionCheckFuture = ApiService.checkStatus(
        widget.token,
        widget.deploymentCode
      );

      final statusResponse = await sessionCheckFuture.timeout(
        _sessionCheckTimeout,
        onTimeout: () {
          print('Dashboard: Session check timed out after ${_sessionCheckTimeout.inSeconds}s');
          throw TimeoutException('Session check timed out', _sessionCheckTimeout);
        },
      );

      if (statusResponse.success && statusResponse.data != null) {
        final isStillLoggedIn = statusResponse.data!['isLoggedIn'] ?? false;

        _consecutiveSessionFailures = 0;

        if (!isStillLoggedIn && _sessionActive && mounted) {
          print('Dashboard: SESSION TERMINATED BY ANOTHER DEVICE - auto-logging out');
          _sessionActive = false;
          await _handleAutomaticLogout();
        } else if (isStillLoggedIn && mounted) {
          if (!_sessionActive) {
            setState(() => _sessionActive = true);
            print('Dashboard: Session restored');
          } else {
            print('Dashboard: Session still active');
          }
        }
      } else {
        print('Dashboard: Session check failed: ${statusResponse.message}');
        await _handleSessionCheckFailure('API error: ${statusResponse.message}');
      }

    } on TimeoutException catch (e) {
      print('Dashboard: Session check timeout: $e');
      await _handleSessionCheckFailure('Timeout: ${e.message}');

    } catch (e) {
      print('Dashboard: Session verification failed: $e');
      await _handleSessionCheckFailure('Network error: $e');

    } finally {
      _isCheckingSession = false;
    }
  }

  Future<void> _handleSessionCheckFailure(String reason) async {
    _consecutiveSessionFailures++;
    print('Dashboard: Session check failure #$_consecutiveSessionFailures: $reason');

    if (_consecutiveSessionFailures >= _maxSessionFailures) {
      print('Dashboard: Too many consecutive session failures ($_consecutiveSessionFailures/$_maxSessionFailures)');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(Icons.warning, color: Colors.white, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: AutoSizeText(
                    'Session verification issues detected. Check your connection.',
                    style: TextStyle(fontSize: 14),
                    maxLines: 2,
                  ),
                ),
              ],
            ),
            backgroundColor: Colors.orange[700],
            duration: Duration(seconds: 5),
          ),
        );
      }

      _consecutiveSessionFailures = 0;
      await Future.delayed(_sessionRetryDelay);
    }
  }

  Future<void> _handleAutomaticLogout() async {
    print('Dashboard: HANDLING AUTOMATIC LOGOUT WITH PROPER CLEANUP');

    try {
      _sessionVerificationTimer?.cancel();
      _sessionVerificationTimer = null;

      _cleanupAllTimers();

      _locationService.dispose();
      _deviceService.dispose();
      _watchdogService.stopWatchdog();

      await _clearStoredCredentials();

      if (mounted) {
        await _showAutomaticLogoutDialog();
      }

    } catch (e) {
      print('Dashboard: Error during automatic logout: $e');
      if (mounted) {
        _navigateToLogin();
      }
    }
  }

  Future<void> _clearStoredCredentials() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('deploymentCode');
      await prefs.setBool('isTokenLocked', false);
      print('Dashboard: Stored credentials cleared');
    } catch (e) {
      print('Dashboard: Error clearing credentials: $e');
    }
  }

  Future<void> _showAutomaticLogoutDialog() async {
    if (!mounted) return;

    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Row(
            children: [
              Icon(Icons.logout, color: Colors.orange, size: scale(28.0)),
              SizedBox(width: scale(12.0)),
              Expanded(
                child: AutoSizeText(
                  'Automatic Logout',
                  style: TextStyle(color: Colors.orange[700]),
                  maxLines: 1,
                  maxFontSize: getResponsiveFont(18.0),
                ),
              ),
            ],
          ),
          content: Container(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: context.responsivePadding(16.0),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.orange, size: scale(24.0)),
                      SizedBox(width: scale(12.0)),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AutoSizeText(
                              'Session Terminated',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.orange[800],
                              ),
                              maxLines: 1,
                              maxFontSize: getResponsiveFont(16.0),
                            ),
                            SizedBox(height: scale(8.0)),
                            AutoSizeText(
                              'Your deployment code "${widget.deploymentCode}" has been logged in from another device.',
                              style: TextStyle(
                                color: Colors.orange[700],
                              ),
                              maxLines: 3,
                              maxFontSize: getResponsiveFont(14.0),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: scale(16.0)),
                AutoSizeText(
                  'You have been automatically logged out. Please login again if you need to continue using this device.',
                  maxLines: 3,
                  maxFontSize: getResponsiveFont(14.0),
                ),
                SizedBox(height: scale(12.0)),
                AutoSizeText(
                  'Detected at: ${DateTime.now().toString().substring(0, 19)}',
                  style: TextStyle(
                    color: Colors.grey[600],
                    fontStyle: FontStyle.italic,
                  ),
                  maxLines: 1,
                  maxFontSize: getResponsiveFont(12.0),
                ),
              ],
            ),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
                minimumSize: Size(scale(120.0), ResponsiveUIService.getResponsiveButtonHeight(
                  context: context,
                  baseHeight: 45.0,
                )),
              ),
              onPressed: () => _navigateToLogin(),
              child: AutoSizeText(
                'Login Again',
                style: TextStyle(fontWeight: FontWeight.bold),
                maxLines: 1,
                maxFontSize: getResponsiveFont(16.0),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _navigateToLogin() {
    if (!mounted) return;

    if (Navigator.canPop(context)) {
      Navigator.of(context).pop();
    }

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const LoginScreen()),
      (route) => false,
    );
  }

  Widget _buildSessionStatusIndicator() {
    final color = _sessionActive ? Colors.green : Colors.red;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.responsiveFont(8.0),
        vertical: context.responsiveFont(4.0),
      ),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(context.responsiveFont(12.0)),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Container(
        width: context.responsiveFont(10.0),
        height: context.responsiveFont(10.0),
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: color.withOpacity(0.3)),
        ),
      ),
    );
  }

  Future<void> _initializeNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);
    await _notifications.initialize(initializationSettings);
    
    // Create notification channel for location alarm
    const AndroidNotificationChannel locationAlarmChannel = AndroidNotificationChannel(
      'location_alarm_channel',
      'Location Status',
      description: 'Alarm for when location service is disabled',
      importance: Importance.max,
      enableVibration: true,
      playSound: true,
    );
    
    await _notifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(locationAlarmChannel);
  }

  void _listenForConnectivityChanges() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((ConnectivityResult result) {
      final wasOnline = _isOnline;
      _isOnline = result != ConnectivityResult.none;

      if (mounted) {
        setState(() {
          _deviceStatus = _deviceService.getDeviceStatus();
        });
      }

      if (!_isOnline && wasOnline) {
        _showConnectionLostNotification();
        _wasOfflineNotificationSent = true;
      } else if (_isOnline && !wasOnline) {
        _handleConnectionRestored();
      }
    });
  }

  Future<void> _handleConnectionRestored() async {
    print('Dashboard: Connection restored, attempting to reconnect...');

    await _notifications.cancel(0);
    _wasOfflineNotificationSent = false;

    _showConnectionRestoredNotification();
    _startPeriodicUpdates();
    await _sendLocationUpdateSafely();

    print('Dashboard: Automatic reconnection completed');
  }

  Future<void> _showConnectionLostNotification() async {
    const AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'connectivity_channel',
      'Connectivity',
      channelDescription: 'Channel for connectivity notifications',
      importance: Importance.max,
      priority: Priority.high,
      sound: RawResourceAndroidNotificationSound('alarm_sound'),
      enableVibration: true,
      visibility: NotificationVisibility.public,
      ongoing: true,
      fullScreenIntent: true,
    );
    const NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);
    await _notifications.show(
      0,
      'Network Connection Lost',
      'Device is offline. Location tracking continues but data cannot be sent. Will auto-reconnect when network is available.',
      platformChannelSpecifics,
    );
  }

  Future<void> _showConnectionRestoredNotification() async {
    const AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'connectivity_channel',
      'Connectivity',
      channelDescription: 'Channel for connectivity notifications',
      importance: Importance.high,
      priority: Priority.high,
      enableVibration: false,
      visibility: NotificationVisibility.public,
      autoCancel: true,
    );
    const NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);
    await _notifications.show(
      1,
      'Connection Restored',
      'Network connection restored. Location tracking resumed successfully.',
      platformChannelSpecifics,
    );

    Timer(const Duration(seconds: 3), () {
      _notifications.cancel(1);
    });
  }

  Future<void> _initializeServices() async {
    if (!mounted) return;

    setState(() => _isLoading = true);

    try {
      await Future.wait([
        _initializeDeviceService(),
        _initializeLocationTracking(),
        _initializeWatchdog(),
        _initializePermanentWakeLock(),
      ], eagerError: false);

      _startPeriodicUpdates();

      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasInitialized = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: AutoSizeText(
              'Initialization error: ${e.toString()}',
              maxFontSize: getResponsiveFont(14.0),
            ),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }
  }

  Future<void> _initializeDeviceService() async {
    await _deviceService.initialize();
    if (mounted) {
      setState(() {
        _deviceStatus = _deviceService.getDeviceStatus();
      });

      if (_deviceService.isOnline) {
        print('Dashboard: Device is online, sending immediate status update to webapp');
        _sendLocationUpdateSafely();
      }
    }
  }

  Future<void> _initializeWatchdog() async {
    try {
      await _watchdogService.initialize(
        onAppDead: () {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('App monitoring was interrupted. Restarting services...'),
                backgroundColor: Colors.orange,
                duration: Duration(seconds: 5),
              ),
            );
            _initializeServices();
          }
        },
      );
      _watchdogService.startWatchdog();
    } catch (e) {
      print('Dashboard: Error initializing watchdog: $e');
    }
  }

  Future<void> _initializePermanentWakeLock() async {
    try {
      await _wakeLockService.initialize();
      await _wakeLockService.forceEnableForCriticalOperation();
      if (mounted) {
        setState(() {
          _wakeLockStatus = _wakeLockService.getDetailedStatus();
        });
      }
    } catch (e) {
      Timer(const Duration(seconds: 5), () {
        _initializePermanentWakeLock();
      });
    }
  }

  Future<void> _initializeLocationTracking() async {
    if (!mounted) return;

    setState(() => _isLocationLoading = true);

    try {
      final hasAccess = await _locationService.checkLocationRequirements();
      if (hasAccess) {
        await _wakeLockService.forceEnableForCriticalOperation();

        final position = await _locationService.getCurrentPosition(
          accuracy: LocationAccuracy.bestForNavigation,
          timeout: const Duration(seconds: 15),
        );

        if (position != null && mounted) {
          setState(() => _isLocationLoading = false);
        }

        _locationService.startLocationTracking(
          (position) {
            if (mounted) {
              setState(() => _isLocationLoading = false);
            }
          },
        );

        Timer(const Duration(seconds: 20), () {
          if (mounted && _isLocationLoading) {
            setState(() => _isLocationLoading = false);
          }
        });

              } else {
          if (mounted) {
            setState(() => _isLocationLoading = false);
          }
        }
    } catch (e) {
      if (mounted) {
        setState(() => _isLocationLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: AutoSizeText(
              'Failed to initialize high-precision location: $e',
              maxFontSize: getResponsiveFont(14.0),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _startPeriodicUpdates() {
    _apiUpdateTimer?.cancel();
    _heartbeatTimer?.cancel();
    _statusUpdateTimer?.cancel();

    _apiUpdateTimer = Timer.periodic(
      AppSettings.apiUpdateInterval,
      (timer) => _sendLocationUpdateSafely(),
    );

    _heartbeatTimer = Timer.periodic(
      const Duration(minutes: 5),
      (timer) {
        _watchdogService.ping();
        _maintainWakeLock();
        if (mounted) {
          setState(() {
            _watchdogStatus = _watchdogService.getStatus();
            _wakeLockStatus = _wakeLockService.getDetailedStatus();
            _deviceStatus = _deviceService.getDeviceStatus();
          });
        }
      },
    );

    _statusUpdateTimer = Timer.periodic(const Duration(seconds: 45), (timer) {
      if (mounted) {
        setState(() {
          _internetSpeed = 100 + (DateTime.now().millisecondsSinceEpoch % 1000) / 10;
          _deviceStatus = _deviceService.getDeviceStatus();
        });
      }
    });

    _sendLocationUpdateSafely();
  }

  Future<void> _maintainWakeLock() async {
    final isEnabled = await _wakeLockService.checkWakeLockStatus();
    if (!isEnabled) {
      await _wakeLockService.forceEnableForCriticalOperation();
    }
  }

  Future<void> _sendLocationUpdateSafely() async {
    if (!_isOnline) {
      print('Dashboard: Offline, skipping location update');
      return;
    }

    try {
      await _sendLocationUpdate();
    } catch (e) {
      print('Dashboard: Error sending location update: $e');
    }
  }

  Future<void> _sendLocationUpdate() async {
    final position = _locationService.currentPosition;
    if (position == null) return;

    try {
      final result = await ApiService.updateLocation(
        token: widget.token,
        deploymentCode: widget.deploymentCode,
        position: position,
        batteryLevel: _deviceService.batteryLevel,
        signalStrength: _deviceService.signalStrength,
      );

      if (result.success) {
        _locationUpdatesSent++;
        _lastSuccessfulUpdate = DateTime.now();
        print('Dashboard: Location update #$_locationUpdatesSent sent successfully');
      } else {
        print('Dashboard: Location update failed: ${result.message}');

        if (result.message.contains('Session expired') || result.message.contains('logged in')) {
          _handleSessionExpired();
        }
      }
    } catch (e) {
      print('Dashboard: Error sending location update: $e');
    }
  }

  void _handleSessionExpired() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: AutoSizeText(
          'Session Expired',
          maxFontSize: getResponsiveFont(18.0),
        ),
        content: AutoSizeText(
          'Your session has expired or you have been logged out from another device. Please login again.',
          maxFontSize: getResponsiveFont(14.0),
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              _performLogout();
            },
            child: AutoSizeText(
              'OK',
              maxFontSize: getResponsiveFont(14.0),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _performLogout() async {
    var connectivityResult = await (Connectivity().checkConnectivity());
    if (connectivityResult == ConnectivityResult.none) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: AutoSizeText(
            'No network connection. Please connect to log out.',
            maxFontSize: getResponsiveFont(14.0),
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: AutoSizeText(
          'Confirm Logout',
          maxFontSize: getResponsiveFont(18.0),
        ),
        content: AutoSizeText(
          'Are you sure you want to log out?',
          maxFontSize: getResponsiveFont(14.0),
        ),
        actions: [
          TextButton(
            child: AutoSizeText(
              'Cancel',
              maxFontSize: getResponsiveFont(14.0),
            ),
            onPressed: () => Navigator.of(context).pop(false),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: AutoSizeText(
              'Logout',
              maxFontSize: getResponsiveFont(14.0),
            ),
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await _executeCancellableAction('Logging out...', () async {
      await ApiService.logout(widget.token, widget.deploymentCode);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('deploymentCode');
      _watchdogService.stopWatchdog();
      try {
        await stopBackgroundServiceSafely();
      } catch (e) {
        print("Dashboard: Error stopping background service: $e");
      }
      await Future.delayed(const Duration(milliseconds: 500));
    });
  }

  Future<void> _executeCancellableAction(String title, Future<void> Function() action) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Center(
        child: Card(
          child: Padding(
            padding: context.responsivePadding(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: context.responsiveFont(40.0),
                  height: context.responsiveFont(40.0),
                  child: const CircularProgressIndicator(),
                ),
                SizedBox(height: context.responsiveFont(16.0)),
                AutoSizeText(
                  title,
                  maxFontSize: getResponsiveFont(16.0),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      await action();
    } catch (e) {
      print("Dashboard: Error during action '$title': $e");
    }

    if (mounted) {
      Navigator.of(context).pop();
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const LoginScreen()),
        (route) => false,
      );
    }
  }

  Color _getBatteryColor(BuildContext context) {
    final level = _deviceService.batteryLevel;
    if (level > 50) return Colors.green;
    if (level > 20) return Colors.orange;
    return Colors.red;
  }

  IconData _getBatteryIcon() {
    final level = _deviceService.batteryLevel;
    final state = _deviceService.batteryState;
    if (state.toString().contains('charging')) return Icons.battery_charging_full;
    if (level > 80) return Icons.battery_full;
    if (level > 60) return Icons.battery_6_bar;
    if (level > 40) return Icons.battery_4_bar;
    if (level > 20) return Icons.battery_2_bar;
    return Icons.battery_1_bar;
  }

  Color _getSignalColor(BuildContext context) {
    switch (_deviceService.signalStrength) {
      case 'strong': return Colors.green;
      case 'moderate': return Theme.of(context).colorScheme.primary;
      case 'weak': return Colors.orange;
      default: return Colors.red;
    }
  }

  Future<void> _refreshLocation() async {
    setState(() => _isLocationLoading = true);
    try {
      final position = await _locationService.getCurrentPosition();
      if (position != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: AutoSizeText(
              'Location refreshed (±${position.accuracy.toStringAsFixed(1)}m)',
              maxFontSize: getResponsiveFont(14.0),
            ),
            backgroundColor: Colors.green,
          ),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: AutoSizeText(
              'Failed to get location.',
              maxFontSize: getResponsiveFont(14.0),
            ),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: AutoSizeText(
              'Failed to refresh location: $e',
              maxFontSize: getResponsiveFont(14.0),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLocationLoading = false);
      }
    }
  }

  Future<void> _refreshDashboard() async {
    print('Dashboard: Starting pull-to-refresh...');

    try {
      await Future.wait([
        _deviceService.refreshDeviceInfo(),
        _refreshLocation(),
        _sendLocationUpdateSafely(),
      ], eagerError: false);

      if (mounted) {
        setState(() {
          _deviceStatus = _deviceService.getDeviceStatus();
          _watchdogStatus = _watchdogService.getStatus();
          _wakeLockStatus = _wakeLockService.getDetailedStatus();
        });
      }

      print('Dashboard: Pull-to-refresh completed successfully');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: AutoSizeText(
              'Dashboard refreshed successfully',
              maxFontSize: getResponsiveFont(14.0),
            ),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      print('Dashboard: Error during pull-to-refresh: $e');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: AutoSizeText(
              'Refresh failed: ${e.toString()}',
              maxFontSize: getResponsiveFont(14.0),
            ),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    return PopScope(
      canPop: false,
      child: Scaffold(
        body: Stack(
          children: [
            Scaffold(
              appBar: AppBar(
                title: AutoSizeText(
                  'Device Monitor',
                  maxFontSize: getResponsiveFont(20.0),
                ),
                actions: [
                  _buildSessionStatusIndicator(),
                  SizedBox(width: context.responsiveFont(8.0)),
                  IconButton(
                    icon: Icon(
                      themeProvider.themeMode == ThemeMode.dark
                          ? Icons.light_mode
                          : Icons.dark_mode,
                      size: ResponsiveUIService.getResponsiveIconSize(
                        context: context,
                        baseIconSize: 24.0,
                      ),
                    ),
                    onPressed: () {
                      themeProvider.toggleTheme();
                    },
                    tooltip: 'Toggle Theme',
                  ),
                ],
              ),
              body: _isLoading
                  ? Center(
                      child: SizedBox(
                        width: context.responsiveFont(48.0),
                        height: context.responsiveFont(48.0),
                        child: CircularProgressIndicator(
                          strokeWidth: context.responsiveFont(3.0),
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _refreshDashboard,
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: Column(
                          children: [
                            // Metrics layout
                            _buildAdaptiveMetricLayout(),
                            
                            Padding(
                              padding: EdgeInsets.all(context.responsiveFont(16.0)),
                              child: SizedBox(
                                width: double.infinity,
                                height: ResponsiveUIService.getResponsiveButtonHeight(
                                  context: context,
                                  baseHeight: 48.0,
                                ),
                                child: ElevatedButton.icon(
                                  onPressed: _performLogout,
                                  icon: Icon(Icons.logout),
                                  label: AutoSizeText(
                                    'Logout',
                                    maxFontSize: getResponsiveFont(16.0),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.red,
                                    foregroundColor: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(height: context.responsiveFont(12.0)),
                          ],
                        ),
                      ),
                    ),
            ),
            if (!_isLocationServiceEnabled)
              Container(
                color: Colors.black.withOpacity(0.85),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.location_off,
                        color: Colors.white,
                        size: 80,
                      ),
                      SizedBox(height: 20),
                      Text(
                        'Location is required to continue',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10.0,
                          fontWeight: FontWeight.bold,
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

  double _calculateAspectRatio() {
    final screenType = ResponsiveUIService.getScreenType(
      MediaQuery.of(context).size.width,
    );
    final orientation = MediaQuery.of(context).orientation;

    switch (screenType) {
      case ScreenType.mobile:
        return orientation == Orientation.landscape ? 1.6 : 1.3;
      case ScreenType.tablet:
        return orientation == Orientation.landscape ? 1.8 : 1.5;
      case ScreenType.desktop:
      case ScreenType.large:
        return orientation == Orientation.landscape ? 2.0 : 1.7;
    }
  }

  /// Builds an adaptive metric layout that automatically adjusts based on screen size
  Widget _buildAdaptiveMetricLayout() {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    final isVerySmallScreen = screenWidth < 320 || screenHeight < 500;
    
    // For very small screens, use Wrap layout for better space utilization
    if (isVerySmallScreen) {
      final spacing = ResponsiveUIService.getMetricCardSpacing(context);
      return Padding(
        padding: context.responsivePadding(),
        child: Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: _buildMetricCards(),
        ),
      );
    }
    
    // For larger screens, use adaptive GridView
    final spacing = ResponsiveUIService.getMetricCardSpacing(context);
    return GridView.count(
      crossAxisCount: ResponsiveUIService.getGridCrossAxisCount(context),
      padding: context.responsivePadding(),
      mainAxisSpacing: spacing,
      crossAxisSpacing: spacing,
      childAspectRatio: _calculateAspectRatio(),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: _buildMetricCards(),
    );
  }

  /// Builds the list of metric cards with improved timestamp formatting
  List<Widget> _buildMetricCards() {
    return [
      MetricCard(
        title: 'Connection',
        icon: _isOnline ? Icons.wifi : Icons.wifi_off,
        iconColor: _isOnline ? Colors.green : Colors.red,
        value: _isOnline ? 'Online' : 'Offline',
        subtitle: _deviceService.getConnectivityDescription(),
      ),
      MetricCard(
        title: 'Battery',
        icon: _getBatteryIcon(),
        iconColor: _getBatteryColor(context),
        value: '${_deviceService.batteryLevel}%',
        subtitle: _deviceService.getBatteryHealthStatus(),
        isRealTime: true,
      ),
      MetricCard(
        title: 'Signal Strength',
        icon: Icons.signal_cellular_alt,
        iconColor: _getSignalColor(context),
        value: _deviceService.signalStrength.toUpperCase(),
        subtitle: '',
        isRealTime: true,
      ),
      MetricCard(
        title: 'Last Update',
        icon: Icons.update,
        iconColor: Theme.of(context).colorScheme.primary,
        value: _formatLastUpdateTime(),
        subtitle: 'Updates Sent: $_locationUpdatesSent',
      ),
      _buildLocationCard(),
      _buildSessionMonitoringCard(),
    ];
  }

  /// Formats the last update time in a human-readable format
  String _formatLastUpdateTime() {
    if (_lastSuccessfulUpdate == null) return "Never";
    
    final now = DateTime.now();
    final difference = now.difference(_lastSuccessfulUpdate!);
    
    if (difference.inMinutes < 1) {
      return "Just now";
    } else if (difference.inMinutes < 60) {
      return "${difference.inMinutes}m ago";
    } else if (difference.inHours < 24) {
      return "${difference.inHours}h ago";
    } else {
      return "${difference.inDays}d ago";
    }
  }



  Widget _buildSessionMonitoringCard() {
    final lastCheckText = _formatSessionCheckTime();

    final statusText = _sessionActive ? 'Active' : 'Lost';
    final failureText = _consecutiveSessionFailures > 0
        ? ' (${_consecutiveSessionFailures} failures)'
        : '';

    return MetricCard(
      title: 'Session Monitor',
      icon: _sessionActive ? Icons.verified_user : Icons.error,
      iconColor: _sessionActive ? Colors.green : Colors.red,
      value: statusText + failureText,
      subtitle: 'Last Check: $lastCheckText',
      isRealTime: true,
    );
  }

  /// Formats the session check time in a human-readable format
  String _formatSessionCheckTime() {
    if (_lastSessionCheck == null) return 'Never';
    
    final now = DateTime.now();
    final difference = now.difference(_lastSessionCheck!);
    
    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else {
      return '${difference.inDays}d ago';
    }
  }





  Widget _buildLocationCard() {
    if (_isLocationLoading) {
      return Card(
        child: Center(
          child: SizedBox(
            width: context.responsiveFont(32.0),
            height: context.responsiveFont(32.0),
            child: CircularProgressIndicator(
              strokeWidth: context.responsiveFont(3.0),
            ),
          ),
        ),
      );
    }

    final position = _locationService.currentPosition;

    if (position == null) {
      return Card(
        child: InkWell(
          onTap: _refreshLocation,
          child: Container(
            padding: context.responsivePadding(),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.location_off,
                  size: ResponsiveUIService.getResponsiveIconSize(
                    context: context,
                    baseIconSize: 24.0,
                  ),
                  color: Colors.red,
                ),
                SizedBox(height: context.responsiveFont(4.0)),
                AutoSizeText(
                  'Location\nUnavailable',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.bold),
                  maxLines: 2,
                  maxFontSize: getResponsiveFont(12.0),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final speedKmh = (position.speed * 3.6).clamp(0.0, double.infinity);
    final speedText = speedKmh < 1.0 ? '0' : speedKmh.toStringAsFixed(0);

    return MetricCard(
      title: 'Location',
      icon: Icons.gps_fixed,
      iconColor: Colors.green,
      value: 'Lat: ${position.latitude.toStringAsFixed(4)}\nLng: ${position.longitude.toStringAsFixed(4)}',
      subtitle: 'Acc: ±${position.accuracy.toStringAsFixed(1)}m • Speed: ${speedText}km/h',
      isRealTime: true,
      onTap: _refreshLocation,
    );
  }


}