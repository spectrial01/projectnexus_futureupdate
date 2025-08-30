import 'dart:async';
import 'dart:math';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Intelligent motion detection service that reduces battery consumption
/// by only tracking location when the device is actually moving
class MotionDetectionService {
  static const String _motionThresholdKey = 'motion_threshold';
  static const String _stationaryTimeoutKey = 'stationary_timeout';
  static const String _motionSensitivityKey = 'motion_sensitivity';
  
  // Default values
  static const double _defaultMotionThreshold = 0.5; // m/s²
  static const Duration _defaultStationaryTimeout = Duration(minutes: 5);
  static const double _defaultMotionSensitivity = 1.0;
  
  // Motion detection state
  bool _isMoving = false;
  bool _isInitialized = false;
  DateTime? _lastMotionTime;
  DateTime? _lastStationaryTime;
  
  // Sensor streams
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;
  StreamSubscription<GyroscopeEvent>? _gyroscopeSubscription;
  StreamSubscription<UserAccelerometerEvent>? _userAccelerometerSubscription;
  
  // Motion detection parameters
  double _motionThreshold = _defaultMotionThreshold;
  Duration _stationaryTimeout = _defaultStationaryTimeout;
  double _motionSensitivity = _defaultMotionSensitivity;
  
  // Motion detection algorithm state
  final List<double> _accelerationBuffer = [];
  final List<double> _gyroscopeBuffer = [];
  static const int _bufferSize = 10;
  
  // Callbacks
  Function(bool isMoving)? _onMotionStateChanged;
  Function(double confidence)? _onMotionConfidenceChanged;
  
  // Singleton pattern
  static final MotionDetectionService _instance = MotionDetectionService._internal();
  factory MotionDetectionService() => _instance;
  MotionDetectionService._internal();
  
  /// Initialize the motion detection service
  Future<void> initialize({
    Function(bool isMoving)? onMotionStateChanged,
    Function(double confidence)? onMotionConfidenceChanged,
  }) async {
    if (_isInitialized) return;
    
    _onMotionStateChanged = onMotionStateChanged;
    _onMotionConfidenceChanged = onMotionConfidenceChanged;
    
    // Load saved settings
    await _loadSettings();
    
    // Start motion detection
    await _startMotionDetection();
    
    _isInitialized = true;
    print('MotionDetectionService: Initialized with threshold: ${_motionThreshold}m/s², timeout: ${_stationaryTimeout.inMinutes}min');
  }
  
  /// Load saved motion detection settings
  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      _motionThreshold = prefs.getDouble(_motionThresholdKey) ?? _defaultMotionThreshold;
      _stationaryTimeout = Duration(minutes: prefs.getInt(_stationaryTimeoutKey) ?? _defaultStationaryTimeout.inMinutes);
      _motionSensitivity = prefs.getDouble(_motionSensitivityKey) ?? _defaultMotionSensitivity;
      
      print('MotionDetectionService: Loaded settings - threshold: ${_motionThreshold}m/s², timeout: ${_stationaryTimeout.inMinutes}min, sensitivity: $_motionSensitivity');
    } catch (e) {
      print('MotionDetectionService: Error loading settings: $e');
    }
  }
  
  /// Save motion detection settings
  Future<void> saveSettings({
    double? motionThreshold,
    Duration? stationaryTimeout,
    double? motionSensitivity,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      if (motionThreshold != null) {
        _motionThreshold = motionThreshold;
        await prefs.setDouble(_motionThresholdKey, motionThreshold);
      }
      
      if (stationaryTimeout != null) {
        _stationaryTimeout = stationaryTimeout;
        await prefs.setInt(_stationaryTimeoutKey, stationaryTimeout.inMinutes);
      }
      
      if (motionSensitivity != null) {
        _motionSensitivity = motionSensitivity;
        await prefs.setDouble(_motionSensitivityKey, motionSensitivity);
      }
      
      print('MotionDetectionService: Settings saved successfully');
    } catch (e) {
      print('MotionDetectionService: Error saving settings: $e');
    }
  }
  
  /// Start motion detection using multiple sensors
  Future<void> _startMotionDetection() async {
    try {
      // Accelerometer for general motion detection
      _accelerometerSubscription = accelerometerEvents.listen(
        (AccelerometerEvent event) => _processAccelerometerData(event),
        onError: (error) => print('MotionDetectionService: Accelerometer error: $error'),
      );
      
      // Gyroscope for rotation detection
      _gyroscopeSubscription = gyroscopeEvents.listen(
        (GyroscopeEvent event) => _processGyroscopeData(event),
        onError: (error) => print('MotionDetectionService: Gyroscope error: $error'),
      );
      
      // User accelerometer for user-initiated motion (filtered)
      _userAccelerometerSubscription = userAccelerometerEvents.listen(
        (UserAccelerometerEvent event) => _processUserAccelerometerData(event),
        onError: (error) => print('MotionDetectionService: User accelerometer error: $error'),
      );
      
      print('MotionDetectionService: Motion detection started successfully');
    } catch (e) {
      print('MotionDetectionService: Error starting motion detection: $e');
    }
  }
  
  /// Process accelerometer data for motion detection
  void _processAccelerometerData(AccelerometerEvent event) {
    // Calculate magnitude of acceleration
    final magnitude = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
    
    // Add to buffer
    _addToBuffer(_accelerationBuffer, magnitude);
    
    // Analyze motion pattern
    _analyzeMotion();
  }
  
  /// Process gyroscope data for rotation detection
  void _processGyroscopeData(GyroscopeEvent event) {
    // Calculate rotation magnitude
    final rotationMagnitude = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
    
    // Add to buffer
    _addToBuffer(_gyroscopeBuffer, rotationMagnitude);
  }
  
  /// Process user accelerometer data (gravity-filtered)
  void _processUserAccelerometerData(UserAccelerometerEvent event) {
    // User accelerometer is already filtered for gravity, so it's good for motion detection
    final magnitude = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
    
    // This can help distinguish between device movement and user movement
    if (magnitude > _motionThreshold * 0.8) {
      _updateMotionState(true, 'user_accelerometer');
    }
  }
  
  /// Add value to circular buffer
  void _addToBuffer(List<double> buffer, double value) {
    buffer.add(value);
    if (buffer.length > _bufferSize) {
      buffer.removeAt(0);
    }
  }
  
  /// Analyze motion patterns to determine if device is moving
  void _analyzeMotion() {
    if (_accelerationBuffer.length < _bufferSize) return;
    
    // Calculate variance to detect motion patterns
    final mean = _accelerationBuffer.reduce((a, b) => a + b) / _accelerationBuffer.length;
    final variance = _accelerationBuffer.map((x) => pow(x - mean, 2)).reduce((a, b) => a + b) / _accelerationBuffer.length;
    
    // Calculate standard deviation
    final stdDev = sqrt(variance);
    
    // Motion detection algorithm
    final isCurrentlyMoving = _detectMotion(stdDev);
    
    // Update motion state if changed
    if (isCurrentlyMoving != _isMoving) {
      _updateMotionState(isCurrentlyMoving, 'accelerometer_analysis');
    }
    
    // Update motion confidence
    final confidence = _calculateMotionConfidence(stdDev);
    _onMotionConfidenceChanged?.call(confidence);
  }
  
  /// Detect motion using multiple criteria
  bool _detectMotion(double stdDev) {
    // Primary motion detection using acceleration variance
    final accelerationMotion = stdDev > _motionThreshold * _motionSensitivity;
    
    // Secondary motion detection using gyroscope
    bool gyroscopeMotion = false;
    if (_gyroscopeBuffer.length >= _bufferSize) {
      final gyroMean = _gyroscopeBuffer.reduce((a, b) => a + b) / _gyroscopeBuffer.length;
      gyroscopeMotion = gyroMean > 0.1; // 0.1 rad/s threshold for rotation
    }
    
    // Combined motion detection
    return accelerationMotion || gyroscopeMotion;
  }
  
  /// Calculate motion confidence (0.0 to 1.0)
  double _calculateMotionConfidence(double stdDev) {
    final normalizedStdDev = (stdDev / _motionThreshold).clamp(0.0, 2.0);
    return (normalizedStdDev / 2.0).clamp(0.0, 1.0);
  }
  
  /// Update motion state and handle state changes
  void _updateMotionState(bool isMoving, String source) {
    if (isMoving == _isMoving) return;
    
    _isMoving = isMoving;
    
    if (isMoving) {
      _lastMotionTime = DateTime.now();
      print('MotionDetectionService: Motion detected via $source');
    } else {
      _lastStationaryTime = DateTime.now();
      print('MotionDetectionService: Device stationary via $source');
    }
    
    // Notify listeners
    _onMotionStateChanged?.call(_isMoving);
  }
  
  /// Check if device is currently moving
  bool get isMoving => _isMoving;
  
  /// Get time since last motion
  Duration? get timeSinceLastMotion {
    if (_lastMotionTime == null) return null;
    return DateTime.now().difference(_lastMotionTime!);
  }
  
  /// Get time since device became stationary
  Duration? get timeSinceStationary {
    if (_lastStationaryTime == null) return null;
    return DateTime.now().difference(_lastStationaryTime!);
  }
  
  /// Check if device has been stationary long enough to consider it truly stationary
  bool get isTrulyStationary {
    if (!_isMoving) return false;
    
    final stationaryTime = timeSinceStationary;
    return stationaryTime != null && stationaryTime >= _stationaryTimeout;
  }
  
  /// Get current motion detection settings
  Map<String, dynamic> get settings => {
    'motionThreshold': _motionThreshold,
    'stationaryTimeout': _stationaryTimeout.inMinutes,
    'motionSensitivity': _motionSensitivity,
  };
  
  /// Get motion statistics for debugging
  Map<String, dynamic> get motionStats => {
    'isMoving': _isMoving,
    'lastMotionTime': _lastMotionTime?.toIso8601String(),
    'lastStationaryTime': _lastStationaryTime?.toIso8601String(),
    'timeSinceLastMotion': timeSinceLastMotion?.inSeconds,
    'timeSinceStationary': timeSinceStationary?.inSeconds,
    'isTrulyStationary': isTrulyStationary,
    'accelerationBufferSize': _accelerationBuffer.length,
    'gyroscopeBufferSize': _gyroscopeBuffer.length,
  };
  
  /// Stop motion detection and clean up resources
  Future<void> dispose() async {
    try {
      await _accelerometerSubscription?.cancel();
      await _gyroscopeSubscription?.cancel();
      await _userAccelerometerSubscription?.cancel();
      
      _accelerometerSubscription = null;
      _gyroscopeSubscription = null;
      _userAccelerometerSubscription = null;
      
      _isInitialized = false;
      print('MotionDetectionService: Disposed successfully');
    } catch (e) {
      print('MotionDetectionService: Error during disposal: $e');
    }
  }
  
  /// Reset motion detection state
  void reset() {
    _isMoving = false;
    _lastMotionTime = null;
    _lastStationaryTime = null;
    _accelerationBuffer.clear();
    _gyroscopeBuffer.clear();
    print('MotionDetectionService: State reset');
  }
}
