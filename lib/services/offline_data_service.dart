import 'dart:async';
import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:geolocator/geolocator.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'api_service.dart';
import 'network_connectivity_service.dart';
import '../utils/constants.dart';

class OfflineDataService {
  static final OfflineDataService _instance = OfflineDataService._internal();
  factory OfflineDataService() => _instance;
  OfflineDataService._internal();

  static Database? _database;
  final NetworkConnectivityService _networkService = NetworkConnectivityService();
  StreamSubscription<bool>? _connectivitySubscription;
  
  // Sync status
  bool _isSyncing = false;
  int _pendingDataCount = 0;
  DateTime? _lastSyncTime;
  
  // Stream controllers for UI updates
  final StreamController<bool> _syncStatusController = StreamController<bool>.broadcast();
  final StreamController<int> _pendingDataController = StreamController<int>.broadcast();
  final StreamController<DateTime?> _lastSyncController = StreamController<DateTime?>.broadcast();
  
  // Getters
  bool get isSyncing => _isSyncing;
  int get pendingDataCount => _pendingDataCount;
  DateTime? get lastSyncTime => _lastSyncTime;
  
  // Streams for UI updates
  Stream<bool> get onSyncStatusChanged => _syncStatusController.stream;
  Stream<int> get onPendingDataChanged => _pendingDataController.stream;
  Stream<DateTime?> get onLastSyncChanged => _lastSyncController.stream;
  
  // Initialize the service
  Future<void> initialize() async {
    try {
      print('OfflineDataService: Initializing...');
      
      // Initialize database
      await _initDatabase();
      
      // Initialize network service
      await _networkService.initialize();
      
      // Listen to connectivity changes
      _connectivitySubscription = _networkService.onConnectivityChanged.listen((isOnline) {
        if (isOnline) {
          _handleConnectionRestored();
        }
      });
      
      // Update pending data count
      await _updatePendingDataCount();
      
      print('OfflineDataService: Initialized successfully');
    } catch (e) {
      print('OfflineDataService: Error initializing: $e');
      rethrow;
    }
  }
  
  // Initialize SQLite database
  Future<void> _initDatabase() async {
    try {
      final databasePath = await getDatabasesPath();
      final path = join(databasePath, 'offline_data.db');
      
      _database = await openDatabase(
        path,
        version: 1,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );
      
      print('OfflineDataService: Database initialized at $path');
    } catch (e) {
      print('OfflineDataService: Error initializing database: $e');
      rethrow;
    }
  }
  
  // Create database tables
  Future<void> _onCreate(Database db, int version) async {
    // Table for offline location data
    await db.execute('''
      CREATE TABLE offline_locations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        token TEXT NOT NULL,
        deployment_code TEXT NOT NULL,
        latitude REAL NOT NULL,
        longitude REAL NOT NULL,
        accuracy REAL,
        altitude REAL,
        speed REAL,
        heading REAL,
        battery_level INTEGER,
        signal_strength TEXT,
        timestamp TEXT NOT NULL,
        sync_status TEXT DEFAULT 'pending',
        retry_count INTEGER DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');
    
    // Table for offline events/logs
    await db.execute('''
      CREATE TABLE offline_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        token TEXT NOT NULL,
        deployment_code TEXT NOT NULL,
        event_type TEXT NOT NULL,
        event_data TEXT,
        timestamp TEXT NOT NULL,
        sync_status TEXT DEFAULT 'pending',
        retry_count INTEGER DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');
    
    // Table for sync history
    await db.execute('''
      CREATE TABLE sync_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_type TEXT NOT NULL,
        data_count INTEGER NOT NULL,
        success_count INTEGER NOT NULL,
        failure_count INTEGER NOT NULL,
        start_time TEXT NOT NULL,
        end_time TEXT,
        error_message TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    
    print('OfflineDataService: Database tables created successfully');
  }
  
  // Handle database upgrades
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Handle future database schema changes here
    print('OfflineDataService: Database upgraded from v$oldVersion to v$newVersion');
  }
  
  // Queue location data for offline storage
  Future<bool> queueLocationData({
    required String token,
    required String deploymentCode,
    required Position position,
    int? batteryLevel,
    String? signalStrength,
  }) async {
    try {
      if (_database == null) {
        print('OfflineDataService: Database not initialized');
        return false;
      }
      
      final battery = batteryLevel ?? await _getBatteryLevel();
      final signal = signalStrength ?? await _getSignalStrength();
      
      final result = await _database!.insert('offline_locations', {
        'token': token,
        'deployment_code': deploymentCode,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracy': position.accuracy,
        'altitude': position.altitude,
        'speed': position.speed,
        'heading': position.heading,
        'battery_level': battery,
        'signal_strength': signal,
        'timestamp': position.timestamp?.toIso8601String() ?? DateTime.now().toIso8601String(),
        'created_at': DateTime.now().toIso8601String(),
      });
      
      if (result > 0) {
        await _updatePendingDataCount();
        print('OfflineDataService: Location data queued successfully (ID: $result)');
        return true;
      }
      
      return false;
    } catch (e) {
      print('OfflineDataService: Error queuing location data: $e');
      return false;
    }
  }
  
  // Queue event data for offline storage
  Future<bool> queueEventData({
    required String token,
    required String deploymentCode,
    required String eventType,
    Map<String, dynamic>? eventData,
  }) async {
    try {
      if (_database == null) {
        print('OfflineDataService: Database not initialized');
        return false;
      }
      
      final result = await _database!.insert('offline_events', {
        'token': token,
        'deployment_code': deploymentCode,
        'event_type': eventType,
        'event_data': eventData != null ? json.encode(eventData) : null,
        'timestamp': DateTime.now().toIso8601String(),
        'created_at': DateTime.now().toIso8601String(),
      });
      
      if (result > 0) {
        await _updatePendingDataCount();
        print('OfflineDataService: Event data queued successfully (ID: $result)');
        return true;
      }
      
      return false;
    } catch (e) {
      print('OfflineDataService: Error queuing event data: $e');
      return false;
    }
  }
  
  // Handle connection restoration
  Future<void> _handleConnectionRestored() async {
    try {
      print('OfflineDataService: Connection restored, starting sync...');
      
      // Wait a bit for connection to stabilize
      await Future.delayed(const Duration(seconds: 2));
      
      // Check if we still have connection
      final isOnline = await _networkService.checkConnectivity();
      if (!isOnline) {
        print('OfflineDataService: Connection not stable, skipping sync');
        return;
      }
      
      // Start synchronization
      await syncOfflineData();
      
    } catch (e) {
      print('OfflineDataService: Error handling connection restoration: $e');
    }
  }
  
  // Synchronize offline data with server
  Future<SyncResult> syncOfflineData() async {
    if (_isSyncing) {
      print('OfflineDataService: Sync already in progress');
      return SyncResult.alreadyInProgress;
    }
    
    try {
      _setSyncingStatus(true);
      print('OfflineDataService: Starting offline data synchronization...');
      
      // Check connectivity
      final isOnline = await _networkService.checkConnectivity();
      if (!isOnline) {
        print('OfflineDataService: No internet connection, cannot sync');
        return SyncResult.noConnection;
      }
      
      // Get pending data
      final pendingLocations = await _getPendingLocationData();
      final pendingEvents = await _getPendingEventData();
      
      if (pendingLocations.isEmpty && pendingEvents.isEmpty) {
        print('OfflineDataService: No pending data to sync');
        _setSyncingStatus(false);
        return SyncResult.noDataToSync;
      }
      
      print('OfflineDataService: Found ${pendingLocations.length} locations and ${pendingEvents.length} events to sync');
      
      // Start sync history record
      final syncId = await _startSyncHistory('full_sync', pendingLocations.length + pendingEvents.length);
      
      int successCount = 0;
      int failureCount = 0;
      String? errorMessage;
      
      // Sync location data
      for (final location in pendingLocations) {
        try {
          final success = await _syncLocationData(location);
          if (success) {
            successCount++;
            await _markLocationAsSynced(location['id']);
          } else {
            failureCount++;
            await _incrementLocationRetryCount(location['id']);
          }
        } catch (e) {
          failureCount++;
          errorMessage = e.toString();
          await _incrementLocationRetryCount(location['id']);
        }
      }
      
      // Sync event data
      for (final event in pendingEvents) {
        try {
          final success = await _syncEventData(event);
          if (success) {
            successCount++;
            await _markEventAsSynced(event['id']);
          } else {
            failureCount++;
            await _incrementEventRetryCount(event['id']);
          }
        } catch (e) {
          failureCount++;
          errorMessage = e.toString();
          await _incrementEventRetryCount(event['id']);
        }
      }
      
      // Complete sync history
      await _completeSyncHistory(syncId, successCount, failureCount, errorMessage);
      
      // Update last sync time
      _lastSyncTime = DateTime.now();
      _lastSyncController.add(_lastSyncTime);
      
      // Update pending data count
      await _updatePendingDataCount();
      
      print('OfflineDataService: Sync completed - Success: $successCount, Failures: $failureCount');
      
      return SyncResult.success(successCount, failureCount);
      
    } catch (e) {
      print('OfflineDataService: Error during sync: $e');
      return SyncResult.error(e.toString());
    } finally {
      _setSyncingStatus(false);
    }
  }
  
  // Get pending location data
  Future<List<Map<String, dynamic>>> _getPendingLocationData() async {
    if (_database == null) return [];
    
    try {
      final results = await _database!.query(
        'offline_locations',
        where: 'sync_status = ? AND retry_count < ?',
        whereArgs: ['pending', 3], // Max 3 retries
        orderBy: 'created_at ASC',
      );
      
      return results;
    } catch (e) {
      print('OfflineDataService: Error getting pending location data: $e');
      return [];
    }
  }
  
  // Get pending event data
  Future<List<Map<String, dynamic>>> _getPendingEventData() async {
    if (_database == null) return [];
    
    try {
      final results = await _database!.query(
        'offline_events',
        where: 'sync_status = ? AND retry_count < ?',
        whereArgs: ['pending', 3], // Max 3 retries
        orderBy: 'created_at ASC',
      );
      
      return results;
    } catch (e) {
      print('OfflineDataService: Error getting pending event data: $e');
      return [];
    }
  }
  
  // Sync individual location data
  Future<bool> _syncLocationData(Map<String, dynamic> location) async {
    try {
      // Instead of recreating Position object, send the raw data directly
      // This avoids compatibility issues with Position constructor parameters
      final url = Uri.parse('${AppConstants.baseUrl}updateLocation');
      final headers = {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${location['token']}',
        'X-Sync-Type': 'offline_sync',
      };
      
      final body = json.encode({
        'deploymentCode': location['deployment_code'],
        'location': {
          'latitude': location['latitude'],
          'longitude': location['longitude'],
          'accuracy': location['accuracy'] ?? 0.0,
          'altitude': location['altitude'] ?? 0.0,
          'speed': location['speed'] ?? 0.0,
          'heading': location['heading'] ?? 0.0,
        },
        'batteryStatus': location['battery_level'] ?? 100,
        'signal': location['signal_strength'] ?? 'unknown',
        'timestamp': location['timestamp'],
        'syncType': 'offline_sync',
        'offlineDataId': location['id'],
      });

      final response = await http.post(
        url, 
        headers: headers, 
        body: body
      ).timeout(const Duration(seconds: 15));
      
      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        return responseData['success'] ?? false;
      }
      
      return false;
    } catch (e) {
      print('OfflineDataService: Error syncing location data: $e');
      return false;
    }
  }
  
  // Sync individual event data
  Future<bool> _syncEventData(Map<String, dynamic> event) async {
    try {
      // For now, we'll just mark events as synced
      // In a real implementation, you might send these to a different endpoint
      print('OfflineDataService: Event synced: ${event['event_type']}');
      return true;
    } catch (e) {
      print('OfflineDataService: Error syncing event data: $e');
      return false;
    }
  }
  
  // Mark location as synced
  Future<void> _markLocationAsSynced(int id) async {
    if (_database == null) return;
    
    try {
      await _database!.update(
        'offline_locations',
        {'sync_status': 'synced'},
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (e) {
      print('OfflineDataService: Error marking location as synced: $e');
    }
  }
  
  // Mark event as synced
  Future<void> _markEventAsSynced(int id) async {
    if (_database == null) return;
    
    try {
      await _database!.update(
        'offline_events',
        {'sync_status': 'synced'},
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (e) {
      print('OfflineDataService: Error marking event as synced: $e');
    }
  }
  
  // Increment retry count for location
  Future<void> _incrementLocationRetryCount(int id) async {
    if (_database == null) return;
    
    try {
      await _database!.rawUpdate('''
        UPDATE offline_locations 
        SET retry_count = retry_count + 1 
        WHERE id = ?
      ''', [id]);
    } catch (e) {
      print('OfflineDataService: Error incrementing location retry count: $e');
    }
  }
  
  // Increment retry count for event
  Future<void> _incrementEventRetryCount(int id) async {
    if (_database == null) return;
    
    try {
      await _database!.rawUpdate('''
        UPDATE offline_events 
        SET retry_count = retry_count + 1 
        WHERE id = ?
      ''', [id]);
    } catch (e) {
      print('OfflineDataService: Error incrementing event retry count: $e');
    }
  }
  
  // Start sync history record
  Future<int> _startSyncHistory(String syncType, int dataCount) async {
    if (_database == null) return 0;
    
    try {
      final result = await _database!.insert('sync_history', {
        'sync_type': syncType,
        'data_count': dataCount,
        'success_count': 0,
        'failure_count': 0,
        'start_time': DateTime.now().toIso8601String(),
        'created_at': DateTime.now().toIso8601String(),
      });
      
      return result;
    } catch (e) {
      print('OfflineDataService: Error starting sync history: $e');
      return 0;
    }
  }
  
  // Complete sync history record
  Future<void> _completeSyncHistory(int syncId, int successCount, int failureCount, String? errorMessage) async {
    if (_database == null || syncId == 0) return;
    
    try {
      await _database!.update(
        'sync_history',
        {
          'success_count': successCount,
          'failure_count': failureCount,
          'end_time': DateTime.now().toIso8601String(),
          'error_message': errorMessage,
        },
        where: 'id = ?',
        whereArgs: [syncId],
      );
    } catch (e) {
      print('OfflineDataService: Error completing sync history: $e');
    }
  }
  
  // Update pending data count
  Future<void> _updatePendingDataCount() async {
    if (_database == null) return;
    
    try {
      final locationCount = Sqflite.firstIntValue(await _database!.rawQuery(
        'SELECT COUNT(*) FROM offline_locations WHERE sync_status = ?',
        ['pending'],
      )) ?? 0;
      
      final eventCount = Sqflite.firstIntValue(await _database!.rawQuery(
        'SELECT COUNT(*) FROM offline_events WHERE sync_status = ?',
        ['pending'],
      )) ?? 0;
      
      _pendingDataCount = locationCount + eventCount;
      _pendingDataController.add(_pendingDataCount);
      
      print('OfflineDataService: Pending data count updated: $_pendingDataCount');
    } catch (e) {
      print('OfflineDataService: Error updating pending data count: $e');
    }
  }
  
  // Set syncing status
  void _setSyncingStatus(bool syncing) {
    _isSyncing = syncing;
    _syncStatusController.add(_isSyncing);
  }
  
  // Get sync statistics
  Future<Map<String, dynamic>> getSyncStatistics() async {
    if (_database == null) return {};
    
    try {
      final totalLocations = Sqflite.firstIntValue(await _database!.rawQuery(
        'SELECT COUNT(*) FROM offline_locations',
      )) ?? 0;
      
      final syncedLocations = Sqflite.firstIntValue(await _database!.rawQuery(
        'SELECT COUNT(*) FROM offline_locations WHERE sync_status = ?',
        ['synced'],
      )) ?? 0;
      
      final pendingLocations = Sqflite.firstIntValue(await _database!.rawQuery(
        'SELECT COUNT(*) FROM offline_locations WHERE sync_status = ?',
        ['pending'],
      )) ?? 0;
      
      final totalEvents = Sqflite.firstIntValue(await _database!.rawQuery(
        'SELECT COUNT(*) FROM offline_events',
      )) ?? 0;
      
      final syncedEvents = Sqflite.firstIntValue(await _database!.rawQuery(
        'SELECT COUNT(*) FROM offline_events WHERE sync_status = ?',
        ['synced'],
      )) ?? 0;
      
      final pendingEvents = Sqflite.firstIntValue(await _database!.rawQuery(
        'SELECT COUNT(*) FROM offline_events WHERE sync_status = ?',
        ['pending'],
      )) ?? 0;
      
      return {
        'totalLocations': totalLocations,
        'syncedLocations': syncedLocations,
        'pendingLocations': pendingLocations,
        'totalEvents': totalEvents,
        'syncedEvents': syncedEvents,
        'pendingEvents': pendingEvents,
        'lastSyncTime': _lastSyncTime?.toIso8601String(),
        'isSyncing': _isSyncing,
      };
    } catch (e) {
      print('OfflineDataService: Error getting sync statistics: $e');
      return {};
    }
  }
  
  // Clear old synced data (cleanup)
  Future<void> clearOldSyncedData({int daysOld = 7}) async {
    if (_database == null) return;
    
    try {
      final cutoffDate = DateTime.now().subtract(Duration(days: daysOld));
      
      // Delete old synced locations
      final deletedLocations = await _database!.delete(
        'offline_locations',
        where: 'sync_status = ? AND created_at < ?',
        whereArgs: ['synced', cutoffDate.toIso8601String()],
      );
      
      // Delete old synced events
      final deletedEvents = await _database!.delete(
        'offline_events',
        where: 'sync_status = ? AND created_at < ?',
        whereArgs: ['synced', cutoffDate.toIso8601String()],
      );
      
      // Delete old sync history
      final deletedHistory = await _database!.delete(
        'sync_history',
        where: 'created_at < ?',
        whereArgs: [cutoffDate.toIso8601String()],
      );
      
      print('OfflineDataService: Cleaned up $deletedLocations locations, $deletedEvents events, $deletedHistory history records');
      
      // Update pending data count
      await _updatePendingDataCount();
      
    } catch (e) {
      print('OfflineDataService: Error clearing old synced data: $e');
    }
  }
  
  // Helper methods
  Future<int> _getBatteryLevel() async {
    try {
      final battery = Battery();
      return await battery.batteryLevel;
    } catch (e) {
      return 100;
    }
  }
  
  Future<String> _getSignalStrength() async {
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
  
  // Dispose resources
  void dispose() {
    _connectivitySubscription?.cancel();
    _syncStatusController.close();
    _pendingDataController.close();
    _lastSyncController.close();
    _database?.close();
  }
}

// Sync result class
class SyncResult {
  final bool isSuccess;
  final String message;
  final int? successCount;
  final int? failureCount;
  
  const SyncResult._({
    required this.isSuccess,
    required this.message,
    this.successCount,
    this.failureCount,
  });
  
  // Factory constructors
  static const SyncResult alreadyInProgress = SyncResult._(
    isSuccess: false,
    message: 'Sync already in progress',
  );
  
  static const SyncResult noConnection = SyncResult._(
    isSuccess: false,
    message: 'No internet connection',
  );
  
  static const SyncResult noDataToSync = SyncResult._(
    isSuccess: true,
    message: 'No data to sync',
  );
  
  static SyncResult success(int successCount, int failureCount) => SyncResult._(
    isSuccess: true,
    message: 'Sync completed successfully',
    successCount: successCount,
    failureCount: failureCount,
  );
  
  static SyncResult error(String errorMessage) => SyncResult._(
    isSuccess: false,
    message: 'Sync failed: $errorMessage',
  );
}
