import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart' as permission_handler;
import 'motion_detection_service.dart';

/// Intelligent location tracking service that optimizes location updates
/// based on device motion to reduce battery consumption
class IntelligentLocationService {
  static const String _locationIntervalKey = 'location_interval';
  static const String _stationaryIntervalKey = 'stationary_interval';
  static const String _motionIntervalKey = 'motion_interval';
  static const String _enableMotionTrackingKey = 'enable_motion_tracking';
  
  // Default intervals
  static const Duration _defaultLocationInterval = Duration(seconds: 5);
  static const Duration _defaultStationaryInterval = Duration(seconds: 5);
  static const Duration _defaultMotionInterval = Duration(seconds: 5);
  
  // Service state
  bool _isInitialized = false;
  bool _isTracking = false;
  bool _isInitializing = false;
  Timer? _locationTimer;
  Timer? _motionCheckTimer;
  
  // Motion detection integration
  final MotionDetectionService _motionService = MotionDetectionService();
  
  // Location tracking parameters
  Duration _locationInterval = _defaultLocationInterval;
  Duration _stationaryInterval = _defaultStationaryInterval;
  Duration _motionInterval = _defaultMotionInterval;
  bool _enableMotionTracking = true;
  
  // Location tracking state
  Position? _lastPosition;
  Position? _currentPosition;
  DateTime? _lastLocationUpdate;
  bool _isCurrentlyMoving = false;
  
  // Location service state
  bool _isLocationEnabled = false;
  bool _hasLocationPermission = false;
  bool _hasBackgroundLocationPermission = false;
  
  // Stream subscription for continuous tracking
  StreamSubscription<Position>? _positionSubscription;
  
  // Callbacks
  Function(Position position)? _onLocationUpdate;
  Function(bool isMoving)? _onMotionStateChanged;
  Function(String status)? _onStatusChanged;
  
  // Singleton pattern
  static final IntelligentLocationService _instance = IntelligentLocationService._internal();
  factory IntelligentLocationService() => _instance;
  IntelligentLocationService._internal();
  
  // Getters for compatibility with LocationService
  Position? get currentPosition => _currentPosition;
  bool get isLocationEnabled => _isLocationEnabled;
  bool get hasLocationPermission => _hasLocationPermission;
  bool get hasBackgroundLocationPermission => _hasBackgroundLocationPermission;
  
  /// Initialize the intelligent location service
  Future<void> initialize({
    Function(Position position)? onLocationUpdate,
    Function(bool isMoving)? onMotionStateChanged,
    Function(String status)? onStatusChanged,
  }) async {
    if (_isInitialized) return;
    
    _onLocationUpdate = onLocationUpdate;
    _onMotionStateChanged = onMotionStateChanged;
    _onStatusChanged = onStatusChanged;
    
    // Load saved settings
    await _loadSettings();
    
    // Initialize motion detection service
    await _motionService.initialize(
      onMotionStateChanged: _handleMotionStateChange,
      onMotionConfidenceChanged: _handleMotionConfidenceChange,
    );
    
    _isInitialized = true;
    print('IntelligentLocationService: Initialized with motion tracking: $_enableMotionTracking');
  }
  
  /// Check location requirements (compatibility method from LocationService)
  Future<bool> checkLocationRequirements() async {
    print('IntelligentLocationService: Checking location requirements...');
    
    final permissionStatus = await permission_handler.Permission.location.status;
    final backgroundPermissionStatus = await permission_handler.Permission.locationAlways.status;
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    
    _hasLocationPermission = permissionStatus.isGranted;
    _hasBackgroundLocationPermission = backgroundPermissionStatus.isGranted;
    _isLocationEnabled = serviceEnabled;
    
    print('IntelligentLocationService: Permission granted: $_hasLocationPermission');
    print('IntelligentLocationService: Background permission granted: $_hasBackgroundLocationPermission');
    print('IntelligentLocationService: Service enabled: $_isLocationEnabled');
    
    return _hasLocationPermission && _hasBackgroundLocationPermission && _isLocationEnabled;
  }
  
  /// Request location permission (compatibility method from LocationService)
  Future<permission_handler.PermissionStatus> requestLocationPermission() async {
    print('IntelligentLocationService: Requesting location permission...');
    
    // Request basic location permission first
    final status = await permission_handler.Permission.location.request();
    _hasLocationPermission = status.isGranted;
    
    // Request background location permission
    if (status.isGranted) {
      final backgroundStatus = await permission_handler.Permission.locationAlways.request();
      _hasBackgroundLocationPermission = backgroundStatus.isGranted;
      
      if (!backgroundStatus.isGranted) {
        print('IntelligentLocationService: Background location permission denied - critical for 24/7 tracking');
      }
    }
    
    // Also request precise location permission on Android
    if (status.isGranted) {
      try {
        final preciseStatus = await permission_handler.Permission.locationWhenInUse.request();
        print('IntelligentLocationService: Precise location permission: $preciseStatus');
      } catch (e) {
        print('IntelligentLocationService: Error requesting precise location: $e');
      }
    }
    
    return status;
  }
  
  /// Get current position (compatibility method from LocationService)
  Future<Position?> getCurrentPosition({
    LocationAccuracy accuracy = LocationAccuracy.bestForNavigation,
    Duration? timeout,
  }) async {
    if (_isInitializing) {
      print('IntelligentLocationService: Already initializing, waiting...');
      await Future.delayed(const Duration(seconds: 2));
    }
    
    _isInitializing = true;
    
    try {
      print('IntelligentLocationService: Getting current position with ${accuracy.toString()} accuracy...');
      
      // First check if we have permission and service is enabled
      final hasRequirements = await checkLocationRequirements();
      if (!hasRequirements) {
        throw 'Location permission or service not available';
      }
      
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: accuracy,
        timeLimit: timeout ?? const Duration(seconds: 15),
        forceAndroidLocationManager: false, // Use Google Play Services for better accuracy
      );
      
      _currentPosition = position;
      _lastPosition = position;
      print('IntelligentLocationService: Position obtained - Lat: ${position.latitude}, Lng: ${position.longitude}, Accuracy: ±${position.accuracy.toStringAsFixed(1)}m');
      
      return position;
    } catch (e) {
      print('IntelligentLocationService: Error getting current position: $e');
      return null;
    } finally {
      _isInitializing = false;
    }
  }
  
  /// Start location tracking (compatibility method from LocationService)
  void startLocationTracking(Function(Position) onLocationUpdate) {
    print('IntelligentLocationService: Starting location tracking...');
    
    _onLocationUpdate = onLocationUpdate;
    
    // Stop any existing subscription
    stopLocationTracking();
    
    try {
      // Get initial position first to provide immediate feedback
      getCurrentPosition().then((initialPosition) {
        if (initialPosition != null) {
          print('IntelligentLocationService: Initial position obtained, starting stream...');
          _onLocationUpdate?.call(initialPosition);
        }
      }).catchError((e) {
        print('IntelligentLocationService: Error getting initial position: $e');
        // Continue with stream anyway
      });
      
      // Use adaptive accuracy based on motion state
      final accuracy = _isCurrentlyMoving ? LocationAccuracy.high : LocationAccuracy.medium;
      final distanceFilter = _isCurrentlyMoving ? 10 : 25; // Less sensitive when stationary
      
      print('IntelligentLocationService: Using ${accuracy.toString()} accuracy with ${distanceFilter}m distance filter');
      
      final LocationSettings locationSettings = LocationSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
        timeLimit: Duration(seconds: 30),
      );
      
      _positionSubscription = Geolocator.getPositionStream(locationSettings: locationSettings).listen(
        (position) {
          _currentPosition = position;
          _lastPosition = position;
          print('IntelligentLocationService: Update - Lat: ${position.latitude}, Lng: ${position.longitude}, Accuracy: ±${position.accuracy.toStringAsFixed(1)}m');
          
          _onLocationUpdate?.call(position);
        },
        onError: (error) {
          print('IntelligentLocationService: Stream error: $error');
          
          // Try to restart the stream after a delay
          Timer(const Duration(seconds: 5), () {
            print('IntelligentLocationService: Attempting to restart location stream...');
            if (_onLocationUpdate != null) {
              startLocationTracking(_onLocationUpdate!);
            }
          });
        },
        cancelOnError: false, // Continue tracking even if there are temporary errors
      );
      
      print('IntelligentLocationService: Location tracking started successfully');
    } catch (e) {
      print('IntelligentLocationService: Error starting location tracking: $e');
    }
  }
  
  /// Stop location tracking (compatibility method from LocationService)
  void stopLocationTracking() {
    print('IntelligentLocationService: Stopping location tracking...');
    _positionSubscription?.cancel();
    _positionSubscription = null;
  }
  
  /// Load saved location tracking settings
  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      _locationInterval = Duration(seconds: prefs.getInt(_locationIntervalKey) ?? _defaultLocationInterval.inSeconds);
      _stationaryInterval = Duration(seconds: prefs.getInt(_stationaryIntervalKey) ?? _defaultStationaryInterval.inSeconds);
      _motionInterval = Duration(seconds: prefs.getInt(_motionIntervalKey) ?? _defaultMotionInterval.inSeconds);
      _enableMotionTracking = prefs.getBool(_enableMotionTrackingKey) ?? _enableMotionTracking;
      
      print('IntelligentLocationService: Loaded settings - location: ${_locationInterval.inSeconds}s, stationary: ${_stationaryInterval.inMinutes}min, motion: ${_motionInterval.inSeconds}s');
    } catch (e) {
      print('IntelligentLocationService: Error loading settings: $e');
    }
  }
  
  /// Save location tracking settings
  Future<void> saveSettings({
    Duration? locationInterval,
    Duration? stationaryInterval,
    Duration? motionInterval,
    bool? enableMotionTracking,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      if (locationInterval != null) {
        _locationInterval = locationInterval;
        await prefs.setInt(_locationIntervalKey, locationInterval.inSeconds);
      }
      
      if (stationaryInterval != null) {
        _stationaryInterval = stationaryInterval;
        await prefs.setInt(_stationaryIntervalKey, stationaryInterval.inSeconds);
      }
      
      if (motionInterval != null) {
        _motionInterval = motionInterval;
        await prefs.setInt(_motionIntervalKey, motionInterval.inSeconds);
      }
      
      if (enableMotionTracking != null) {
        _enableMotionTracking = enableMotionTracking;
        await prefs.setBool(_enableMotionTrackingKey, enableMotionTracking);
      }
      
      print('IntelligentLocationService: Settings saved successfully');
    } catch (e) {
      print('IntelligentLocationService: Error saving settings: $e');
    }
  }
  
  /// Start intelligent location tracking
  Future<void> startTracking() async {
    if (!_isInitialized || _isTracking) return;
    
    try {
      _isTracking = true;
      
      // Start motion monitoring timer
      if (_enableMotionTracking) {
        _motionCheckTimer = Timer.periodic(_motionInterval, (timer) {
          _updateMotionState();
        });
        print('IntelligentLocationService: Motion monitoring started');
      }
      
      // Start location tracking with initial interval
      _startLocationTracking();
      
      _onStatusChanged?.call('Intelligent location tracking started');
      print('IntelligentLocationService: Location tracking started');
    } catch (e) {
      print('IntelligentLocationService: Error starting tracking: $e');
      _isTracking = false;
    }
  }
  
  /// Stop intelligent location tracking
  Future<void> stopTracking() async {
    if (!_isTracking) return;
    
    try {
      _isTracking = false;
      
      // Stop timers
      _locationTimer?.cancel();
      _motionCheckTimer?.cancel();
      
      _locationTimer = null;
      _motionCheckTimer = null;
      
      _onStatusChanged?.call('Location tracking stopped');
      print('IntelligentLocationService: Location tracking stopped');
    } catch (e) {
      print('IntelligentLocationService: Error stopping tracking: $e');
    }
  }
  
  /// Start location tracking with appropriate interval
  void _startLocationTracking() {
    // Cancel existing timer
    _locationTimer?.cancel();
    
    // Determine tracking interval based on motion state
    final interval = _getOptimalTrackingInterval();
    
    _locationTimer = Timer.periodic(interval, (timer) async {
      await _performLocationUpdate();
    });
    
    print('IntelligentLocationService: Location tracking started with interval: ${interval.inSeconds}s');
  }
  
  /// Get optimal tracking interval based on motion state
  Duration _getOptimalTrackingInterval() {
    if (!_enableMotionTracking) {
      return _locationInterval; // Use default interval if motion tracking disabled
    }
    
    if (_isCurrentlyMoving) {
      return _motionInterval; // More frequent updates when moving
    } else {
      // Check if device has been stationary long enough
      if (_motionService.isTrulyStationary) {
        return _stationaryInterval; // Much less frequent when truly stationary
      } else {
        return _locationInterval; // Default interval when recently stationary
      }
    }
  }
  
  /// Update motion state from motion detection service
  void _updateMotionState() {
    if (!_enableMotionTracking) return;
    
    final wasMoving = _isCurrentlyMoving;
    _isCurrentlyMoving = _motionService.isMoving;
    
    // If motion state changed, adjust tracking interval
    if (wasMoving != _isCurrentlyMoving) {
      _onMotionStateChanged?.call(_isCurrentlyMoving);
      _restartLocationTrackingWithNewInterval();
    }
  }
  
  /// Restart location tracking with new interval based on motion state
  void _restartLocationTrackingWithNewInterval() {
    if (!_isTracking) return;
    
    final newInterval = _getOptimalTrackingInterval();
    final currentInterval = _locationTimer?.tick ?? 0;
      
    // Only restart if interval changed significantly
    if ((newInterval.inSeconds - currentInterval).abs() > 5) {
      print('IntelligentLocationService: Motion state changed, adjusting tracking interval to ${newInterval.inSeconds}s');
      _startLocationTracking();
    }
  }
  
  /// Handle motion state change from motion detection service
  void _handleMotionStateChange(bool isMoving) {
    _isCurrentlyMoving = isMoving;
    _onMotionStateChanged?.call(isMoving);
    
    if (_isTracking) {
      _restartLocationTrackingWithNewInterval();
    }
  }
  
  /// Handle motion confidence change
  void _handleMotionConfidenceChange(double confidence) {
    // Could be used for adaptive threshold adjustment
    if (confidence > 0.8 && _isCurrentlyMoving) {
      // High confidence motion - could increase tracking frequency
      print('IntelligentLocationService: High confidence motion detected (${(confidence * 100).toStringAsFixed(1)}%)');
    }
  }
  
  /// Perform location update
  Future<void> _performLocationUpdate() async {
    try {
      // Check if we should skip this update
      if (_shouldSkipLocationUpdate()) {
        return;
      }
      
      // Get current position
      final position = await _getCurrentPosition();
      if (position == null) return;
      
      // Update state
      _lastPosition = position;
      _currentPosition = position;
      _lastLocationUpdate = DateTime.now();
      
      // Notify listeners
      _onLocationUpdate?.call(position);
      
      // Log update
      final motionStatus = _isCurrentlyMoving ? 'MOVING' : 'STATIONARY';
      final interval = _getOptimalTrackingInterval();
      print('IntelligentLocationService: Location update - $motionStatus, interval: ${interval.inSeconds}s, accuracy: ${position.accuracy.toStringAsFixed(1)}m');
      
    } catch (e) {
      print('IntelligentLocationService: Error performing location update: $e');
    }
  }
  
  /// Check if location update should be skipped
  bool _shouldSkipLocationUpdate() {
    if (!_enableMotionTracking) return false;
    
    // Skip update if device is truly stationary and we're using stationary interval
    if (!_isCurrentlyMoving && _motionService.isTrulyStationary) {
      final timeSinceLastUpdate = _lastLocationUpdate != null 
          ? DateTime.now().difference(_lastLocationUpdate!).inSeconds 
          : 0;
      
      // Skip if we haven't reached the stationary interval yet
      if (timeSinceLastUpdate < _stationaryInterval.inSeconds) {
        return true;
      }
    }
    
    return false;
  }
  
  /// Get current position with error handling
  Future<Position?> _getCurrentPosition() async {
    try {
      // Check location permissions
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          print('IntelligentLocationService: Location permission denied');
          return null;
        }
      }
      
      if (permission == LocationPermission.deniedForever) {
        print('IntelligentLocationService: Location permission permanently denied');
        return null;
      }
      
      // Check if location services are enabled
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        print('IntelligentLocationService: Location services are disabled');
        return null;
      }
      
      // Get current position with appropriate accuracy
      final accuracy = _isCurrentlyMoving ? LocationAccuracy.high : LocationAccuracy.medium;
      final timeLimit = _isCurrentlyMoving ? const Duration(seconds: 10) : const Duration(seconds: 15);
      
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: accuracy,
        timeLimit: timeLimit,
      );
      
      return position;
    } catch (e) {
      print('IntelligentLocationService: Error getting current position: $e');
      return null;
    }
  }
  
  /// Get current tracking status
  Map<String, dynamic> get trackingStatus => {
    'isTracking': _isTracking,
    'isMoving': _isCurrentlyMoving,
    'currentInterval': _locationTimer?.tick ?? 0,
    'optimalInterval': _getOptimalTrackingInterval().inSeconds,
    'lastUpdate': _lastLocationUpdate?.toIso8601String(),
    'motionTrackingEnabled': _enableMotionTracking,
    'motionStats': _motionService.motionStats,
    'currentAccuracy': _isCurrentlyMoving ? 'high' : 'medium',
    'currentDistanceFilter': _isCurrentlyMoving ? 10 : 25,
  };
  
  /// Get current motion state
  bool get isCurrentlyMoving => _isCurrentlyMoving;
  
  /// Get current accuracy setting
  LocationAccuracy get currentAccuracy => _isCurrentlyMoving ? LocationAccuracy.high : LocationAccuracy.medium;
  
  /// Get current distance filter setting
  int get currentDistanceFilter => _isCurrentlyMoving ? 10 : 25;
  
  /// Get current settings
  Map<String, dynamic> get settings => {
    'locationInterval': _locationInterval.inSeconds,
    'stationaryInterval': _stationaryInterval.inMinutes,
    'motionInterval': _motionInterval.inSeconds,
    'enableMotionTracking': _enableMotionTracking,
  };
  
  /// Get last known position
  Position? get lastPosition => _lastPosition;
  
  /// Check if service is currently tracking
  bool get isTracking => _isTracking;
  
  /// Check if device is currently moving
  bool get isMoving => _isCurrentlyMoving;
  
  /// Dispose of the service
  Future<void> dispose() async {
    try {
      await stopTracking();
      stopLocationTracking(); // Stop the compatibility stream
      await _motionService.dispose();
      _isInitialized = false;
      print('IntelligentLocationService: Disposed successfully');
    } catch (e) {
      print('IntelligentLocationService: Error during disposal: $e');
    }
  }
}
