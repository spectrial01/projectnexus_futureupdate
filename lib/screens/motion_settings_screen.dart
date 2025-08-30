import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/motion_detection_service.dart';
import '../services/intelligent_location_service.dart';
import '../services/theme_provider.dart';

class MotionSettingsScreen extends StatefulWidget {
  const MotionSettingsScreen({super.key});

  @override
  State<MotionSettingsScreen> createState() => _MotionSettingsScreenState();
}

class _MotionSettingsScreenState extends State<MotionSettingsScreen> {
  final MotionDetectionService _motionService = MotionDetectionService();
  final IntelligentLocationService _locationService = IntelligentLocationService();
  
  // Motion detection settings
  double _motionThreshold = 0.5;
  int _stationaryTimeout = 5;
  double _motionSensitivity = 1.0;
  
  // Location tracking settings
  int _locationInterval = 5;
  int _stationaryInterval = 5;
  int _motionInterval = 5;
  bool _enableMotionTracking = true;
  
  // UI state
  bool _isLoading = true;
  Map<String, dynamic>? _motionStats;
  Map<String, dynamic>? _trackingStatus;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      // Load motion detection settings
      final motionSettings = _motionService.settings;
      _motionThreshold = motionSettings['motionThreshold'] ?? 0.5;
      _stationaryTimeout = motionSettings['stationaryTimeout'] ?? 5;
      _motionSensitivity = motionSettings['motionSensitivity'] ?? 1.0;
      
      // Load location tracking settings
      final locationSettings = _locationService.settings;
      _locationInterval = locationSettings['locationInterval'] ?? 15;
      _stationaryInterval = locationSettings['stationaryInterval'] ?? 5;
      _motionInterval = locationSettings['motionInterval'] ?? 10;
      _enableMotionTracking = locationSettings['enableMotionTracking'] ?? true;
      
      // Get current stats
      _motionStats = _motionService.motionStats;
      _trackingStatus = _locationService.trackingStatus;
      
      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      print('Error loading motion settings: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _saveSettings() async {
    try {
      // Save motion detection settings
      await _motionService.saveSettings(
        motionThreshold: _motionThreshold,
        stationaryTimeout: Duration(minutes: _stationaryTimeout),
        motionSensitivity: _motionSensitivity,
      );
      
             // Save location tracking settings
       await _locationService.saveSettings(
         locationInterval: Duration(seconds: _locationInterval),
         stationaryInterval: Duration(seconds: _stationaryInterval),
         motionInterval: Duration(seconds: _motionInterval),
         enableMotionTracking: _enableMotionTracking,
       );
      
      // Refresh stats
      _motionStats = _motionService.motionStats;
      _trackingStatus = _locationService.trackingStatus;
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Settings saved successfully'),
            backgroundColor: Colors.green,
          ),
        );
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving settings: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, child) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Motion & Location Settings'),
            backgroundColor: themeProvider.isDarkMode ? Colors.grey[900] : Colors.blue[600],
            foregroundColor: Colors.white,
            actions: [
              IconButton(
                icon: const Icon(Icons.save),
                onPressed: _saveSettings,
                tooltip: 'Save Settings',
              ),
            ],
          ),
          body: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildMotionDetectionSection(),
                      const SizedBox(height: 24),
                      _buildLocationTrackingSection(),
                      const SizedBox(height: 24),
                      _buildCurrentStatusSection(),
                      const SizedBox(height: 24),
                      _buildBatteryOptimizationInfo(),
                    ],
                  ),
                ),
        );
      },
    );
  }

  Widget _buildMotionDetectionSection() {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.sensors, color: Colors.blue[600]),
                const SizedBox(width: 8),
                const Text(
                  'Motion Detection',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            // Motion Threshold
            Text(
              'Motion Threshold: ${_motionThreshold.toStringAsFixed(1)} m/s²',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            Slider(
              value: _motionThreshold,
              min: 0.1,
              max: 2.0,
              divisions: 19,
              label: '${_motionThreshold.toStringAsFixed(1)} m/s²',
              onChanged: (value) {
                setState(() {
                  _motionThreshold = value;
                });
              },
            ),
            const Text(
              'Lower values = more sensitive to motion',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            
            const SizedBox(height: 16),
            
            // Stationary Timeout
            Text(
              'Stationary Timeout: ${_stationaryTimeout} minutes',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            Slider(
              value: _stationaryTimeout.toDouble(),
              min: 1,
              max: 30,
              divisions: 29,
              label: '${_stationaryTimeout} min',
              onChanged: (value) {
                setState(() {
                  _stationaryTimeout = value.round();
                });
              },
            ),
            const Text(
              'Time before device is considered truly stationary',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            
            const SizedBox(height: 16),
            
            // Motion Sensitivity
            Text(
              'Motion Sensitivity: ${(_motionSensitivity * 100).toStringAsFixed(0)}%',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            Slider(
              value: _motionSensitivity,
              min: 0.5,
              max: 2.0,
              divisions: 15,
              label: '${(_motionSensitivity * 100).toStringAsFixed(0)}%',
              onChanged: (value) {
                setState(() {
                  _motionSensitivity = value;
                });
              },
            ),
            const Text(
              'Multiplier for motion threshold',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLocationTrackingSection() {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.location_on, color: Colors.green[600]),
                const SizedBox(width: 8),
                const Text(
                  'Location Tracking',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            // Enable Motion Tracking
            SwitchListTile(
              title: const Text('Enable Motion-Based Tracking'),
              subtitle: const Text('Reduce battery usage when device is stationary'),
              value: _enableMotionTracking,
              onChanged: (value) {
                setState(() {
                  _enableMotionTracking = value;
                });
              },
            ),
            
            if (_enableMotionTracking) ...[
              const SizedBox(height: 16),
              
              // Location Interval (when moving)
              Text(
                'Location Update Interval (Moving): ${_motionInterval} seconds',
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              Slider(
                value: _motionInterval.toDouble(),
                min: 5,
                max: 5,
                divisions: 0,
                label: '${_motionInterval}s',
                onChanged: (value) {
                  setState(() {
                    _motionInterval = value.round();
                  });
                },
              ),
              const Text(
                'Fixed 5-second interval when device is moving',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              
              const SizedBox(height: 16),
              
              // Stationary Interval
              Text(
                'Location Update Interval (Stationary): ${_stationaryInterval} seconds',
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              Slider(
                value: _stationaryInterval.toDouble(),
                min: 5,
                max: 5,
                divisions: 0,
                label: '${_stationaryInterval}s',
                onChanged: (value) {
                  setState(() {
                    _stationaryInterval = value.round();
                  });
                },
              ),
              const Text(
                'Fixed 5-second interval when device is stationary',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ] else ...[
              const SizedBox(height: 16),
              
              // Default Location Interval
              Text(
                'Location Update Interval: ${_locationInterval} seconds',
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              Slider(
                value: _locationInterval.toDouble(),
                min: 5,
                max: 5,
                divisions: 0,
                label: '${_locationInterval}s',
                onChanged: (value) {
                  setState(() {
                    _locationInterval = value.round();
                  });
                },
              ),
              const Text(
                'Fixed 5-second interval for location updates',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCurrentStatusSection() {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info, color: Colors.orange[600]),
                const SizedBox(width: 8),
                const Text(
                  'Current Status',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            if (_motionStats != null) ...[
              _buildStatusRow('Motion State', _motionStats!['isMoving'] ? 'Moving' : 'Stationary'),
              _buildStatusRow('Time Since Last Motion', 
                  _motionStats!['timeSinceLastMotion'] != null 
                      ? '${_motionStats!['timeSinceLastMotion']}s ago'
                      : 'N/A'),
              _buildStatusRow('Time Since Stationary', 
                  _motionStats!['timeSinceStationary'] != null 
                      ? '${_motionStats!['timeSinceStationary']}s ago'
                      : 'N/A'),
              _buildStatusRow('Truly Stationary', _motionStats!['isTrulyStationary'] ? 'Yes' : 'No'),
            ],
            
            if (_trackingStatus != null) ...[
              const SizedBox(height: 8),
              _buildStatusRow('Location Tracking', _trackingStatus!['isTracking'] ? 'Active' : 'Inactive'),
              _buildStatusRow('Current Interval', '${_trackingStatus!['currentInterval']}s'),
              _buildStatusRow('Optimal Interval', '${_trackingStatus!['optimalInterval']}s'),
              _buildStatusRow('Motion Tracking', _trackingStatus!['motionTrackingEnabled'] ? 'Enabled' : 'Disabled'),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
          Text(value, style: const TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildBatteryOptimizationInfo() {
    return Card(
      elevation: 4,
      color: Colors.blue[50],
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.battery_saver, color: Colors.blue[600]),
                const SizedBox(width: 8),
                const Text(
                  'Battery Optimization',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'This intelligent tracking system can reduce battery consumption by up to 70% when your device is stationary. '
              'The system automatically adjusts location update frequency based on device motion:',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 8),
            const Text('• More frequent updates when moving (for accuracy)'),
            const Text('• Reduced updates when stationary (to save battery)'),
            const Text('• Adaptive thresholds based on your usage patterns'),
            const Text('• Motion detection using accelerometer and gyroscope'),
          ],
        ),
      ),
    );
  }
}
