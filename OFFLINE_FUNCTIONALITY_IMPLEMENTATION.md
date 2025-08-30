# Offline Functionality Implementation

## Overview

This document describes the comprehensive offline functionality implementation for the PNP Nexus app, addressing the bug where data collected while offline could be lost during the syncing process.

## Key Features Implemented

### 1. **Local Database Storage (SQLite)**
- **Technology**: Uses `sqflite` package for robust local data storage
- **Tables**: 
  - `offline_locations`: Stores location data when offline
  - `offline_events`: Stores event/log data when offline
  - `sync_history`: Tracks synchronization attempts and results

### 2. **Intelligent Data Queuing**
- **Automatic Queuing**: Data is automatically queued when device goes offline
- **Smart Fallback**: If server requests fail, data is queued for later sync
- **No Data Loss**: All location updates are preserved regardless of network status

### 3. **Robust Synchronization**
- **Automatic Sync**: Data syncs automatically when connection is restored
- **Retry Logic**: Failed sync attempts are retried up to 3 times
- **Conflict Resolution**: Handles data conflicts gracefully during sync
- **Batch Processing**: Efficiently processes multiple queued items

### 4. **Visual Indicators**
- **Enhanced Offline Indicator**: Shows offline status, sync progress, and pending data count
- **Sync Status Widget**: Detailed view of synchronization statistics and manual controls
- **Real-time Updates**: Live status updates via streams

## Architecture

### Services

#### OfflineDataService
```dart
class OfflineDataService {
  // Core functionality
  Future<bool> queueLocationData({...})
  Future<bool> queueEventData({...})
  Future<SyncResult> syncOfflineData()
  
  // Statistics and monitoring
  Future<Map<String, dynamic>> getSyncStatistics()
  Stream<bool> get onSyncStatusChanged
  Stream<int> get onPendingDataChanged
}
```

#### NetworkConnectivityService
- Monitors network connectivity changes
- Triggers automatic sync when connection is restored
- Provides real-time connectivity status

#### BackgroundService Integration
- Automatically queues location data when offline
- Seamlessly switches between online and offline modes
- Maintains data collection regardless of network status

### Data Flow

```
Location Update Request
         ↓
   Network Available?
         ↓
    ┌─────────┐    ┌─────────┐
    │   Yes   │    │   No    │
    ↓         ↓    ↓         ↓
Send to Server  │   Queue Data
    ↓         │   Locally
Success?        │         │
    ↓         │         │
    ┌─────────┐         │
    │  Yes    │         │
    ↓         ↓         │
   Complete   │         │
              └─────────┘
                   │
              Connection Restored
                   │
              Auto-Sync Queued Data
```

## Implementation Details

### 1. **Database Schema**

#### Offline Locations Table
```sql
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
);
```

#### Offline Events Table
```sql
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
);
```

### 2. **Synchronization Logic**

#### Automatic Sync Trigger
- Network connectivity restoration
- Manual sync button in UI
- Background service periodic checks

#### Sync Process
1. **Validation**: Check network connectivity and authentication
2. **Data Retrieval**: Get all pending data from local database
3. **Batch Processing**: Process items in order of creation
4. **Server Communication**: Send data to appropriate endpoints
5. **Status Update**: Mark successful items as synced
6. **Retry Management**: Increment retry count for failed items
7. **Cleanup**: Remove old synced data after successful sync

### 3. **Error Handling**

#### Network Failures
- Data remains queued locally
- Automatic retry on next sync attempt
- Exponential backoff for repeated failures

#### Server Errors
- Failed items are marked for retry
- Maximum retry limit prevents infinite loops
- Error logging for debugging

#### Data Corruption
- Validation before sync attempts
- Graceful degradation for invalid data
- Cleanup of corrupted entries

## User Interface Components

### 1. **Enhanced Offline Indicator**

```dart
EnhancedOfflineIndicator(
  onRetry: () => _refreshDashboard(),
  showRetryButton: true,
  showSyncStatus: true,
  showPendingData: true,
)
```

**Features:**
- Shows offline status with color-coded indicators
- Displays sync progress with spinner
- Shows pending data count
- Provides retry functionality
- Automatically hides when all data is synced

### 2. **Sync Status Widget**

```dart
SyncStatusWidget(
  showDetailedStats: true,
  showManualSyncButton: true,
)
```

**Features:**
- Real-time sync statistics
- Manual sync controls
- Data cleanup options
- Visual progress indicators
- Detailed breakdown by data type

## Usage Examples

### 1. **Basic Offline Data Queuing**

```dart
final offlineService = OfflineDataService();

// Queue location data when offline
await offlineService.queueLocationData(
  token: 'user_token',
  deploymentCode: 'deployment_code',
  position: currentPosition,
  batteryLevel: 85,
  signalStrength: 'strong',
);
```

### 2. **Manual Synchronization**

```dart
// Trigger manual sync
final result = await offlineService.syncOfflineData();

if (result.isSuccess) {
  print('Sync completed: ${result.successCount} items synced');
} else {
  print('Sync failed: ${result.message}');
}
```

### 3. **Monitoring Sync Status**

```dart
// Listen to sync status changes
offlineService.onSyncStatusChanged.listen((isSyncing) {
  if (isSyncing) {
    print('Sync in progress...');
  } else {
    print('Sync completed');
  }
});

// Listen to pending data changes
offlineService.onPendingDataChanged.listen((count) {
  print('Pending items: $count');
});
```

## Configuration Options

### 1. **Retry Settings**
- **Max Retries**: 3 attempts per item
- **Retry Delay**: Exponential backoff
- **Cleanup Threshold**: 7 days for old synced data

### 2. **Sync Behavior**
- **Auto-sync**: Enabled by default
- **Batch Size**: Configurable for performance
- **Timeout**: 15 seconds per sync attempt

### 3. **Storage Management**
- **Database Path**: Automatic platform-specific location
- **Cleanup Schedule**: Weekly automatic cleanup
- **Data Retention**: Configurable retention period

## Performance Considerations

### 1. **Database Optimization**
- Indexed queries for fast data retrieval
- Batch operations for multiple items
- Efficient cleanup of old data

### 2. **Memory Management**
- Stream-based updates for real-time UI
- Lazy loading of statistics
- Automatic resource cleanup

### 3. **Battery Optimization**
- Minimal background processing
- Efficient data queuing
- Smart sync scheduling

## Testing Scenarios

### 1. **Offline Mode Testing**
- Enable airplane mode
- Collect location data
- Verify data is queued locally
- Re-enable network
- Verify automatic sync

### 2. **Network Interruption Testing**
- Start data collection
- Interrupt network connection
- Continue collecting data
- Restore connection
- Verify data sync

### 3. **Sync Conflict Testing**
- Queue data while offline
- Modify data on server
- Restore connection
- Verify conflict resolution

### 4. **Performance Testing**
- Large amounts of offline data
- Multiple sync attempts
- Memory usage monitoring
- Battery impact assessment

## Troubleshooting

### Common Issues

#### 1. **Data Not Syncing**
- Check network connectivity
- Verify authentication status
- Check sync service logs
- Manually trigger sync

#### 2. **High Memory Usage**
- Check pending data count
- Clear old synced data
- Monitor database size
- Restart app if necessary

#### 3. **Sync Failures**
- Check server availability
- Verify API endpoints
- Check authentication tokens
- Review error logs

### Debug Information

#### Log Tags
- `OfflineDataService`: Core offline functionality
- `BackgroundService`: Background data collection
- `NetworkConnectivityService`: Network monitoring

#### Key Metrics
- Pending data count
- Sync success/failure rates
- Database size and performance
- Network connectivity status

## Future Enhancements

### 1. **Advanced Sync Features**
- **Incremental Sync**: Only sync changed data
- **Conflict Resolution**: User-controlled conflict handling
- **Sync Scheduling**: Configurable sync intervals
- **Priority Queuing**: Important data syncs first

### 2. **Data Management**
- **Compression**: Reduce storage requirements
- **Encryption**: Secure local data storage
- **Backup/Restore**: Data portability
- **Versioning**: Track data changes over time

### 3. **User Experience**
- **Sync Progress**: Detailed progress indicators
- **Notifications**: Sync status notifications
- **Settings**: User-configurable sync options
- **Analytics**: Sync performance metrics

## Conclusion

The offline functionality implementation provides a robust, user-friendly solution for data collection and synchronization. Key benefits include:

- **No Data Loss**: All data is preserved regardless of network status
- **Seamless Experience**: Automatic switching between online/offline modes
- **Visual Feedback**: Clear indicators of sync status and progress
- **Reliable Sync**: Robust error handling and retry mechanisms
- **Performance Optimized**: Efficient local storage and sync processes

This implementation ensures that users can continue using the app effectively even in poor network conditions, with confidence that their data will be synchronized when connectivity is restored.
