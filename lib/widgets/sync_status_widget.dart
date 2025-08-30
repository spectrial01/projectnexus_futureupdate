import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/offline_data_service.dart';
import '../services/network_connectivity_service.dart';

class SyncStatusWidget extends StatefulWidget {
  final bool showDetailedStats;
  final bool showManualSyncButton;
  
  const SyncStatusWidget({
    super.key,
    this.showDetailedStats = true,
    this.showManualSyncButton = true,
  });

  @override
  State<SyncStatusWidget> createState() => _SyncStatusWidgetState();
}

class _SyncStatusWidgetState extends State<SyncStatusWidget> {
  final OfflineDataService _offlineService = OfflineDataService();
  final NetworkConnectivityService _networkService = NetworkConnectivityService();
  
  bool _isSyncing = false;
  int _pendingDataCount = 0;
  DateTime? _lastSyncTime;
  Map<String, dynamic> _syncStats = {};
  bool _isOnline = true;
  
  @override
  void initState() {
    super.initState();
    _listenToSyncStatus();
    _listenToPendingData();
    _listenToLastSync();
    _listenToConnectivity();
    _loadSyncStats();
  }
  
  void _listenToSyncStatus() {
    _offlineService.onSyncStatusChanged.listen((isSyncing) {
      if (mounted) {
        setState(() {
          _isSyncing = isSyncing;
        });
      }
    });
  }
  
  void _listenToPendingData() {
    _offlineService.onPendingDataChanged.listen((count) {
      if (mounted) {
        setState(() {
          _pendingDataCount = count;
        });
      }
    });
  }
  
  void _listenToLastSync() {
    _offlineService.onLastSyncChanged.listen((lastSync) {
      if (mounted) {
        setState(() {
          _lastSyncTime = lastSync;
        });
      }
    });
  }
  
  void _listenToConnectivity() {
    _networkService.onConnectivityChanged.listen((isOnline) {
      if (mounted) {
        setState(() {
          _isOnline = isOnline;
        });
      }
    });
  }
  
  Future<void> _loadSyncStats() async {
    try {
      final stats = await _offlineService.getSyncStatistics();
      if (mounted) {
        setState(() {
          _syncStats = stats;
        });
      }
    } catch (e) {
      print('SyncStatusWidget: Error loading sync stats: $e');
    }
  }
  
  Future<void> _manualSync() async {
    if (_isSyncing || !_isOnline) return;
    
    try {
      final result = await _offlineService.syncOfflineData();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.message),
            backgroundColor: result.isSuccess ? Colors.green : Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
        
        // Reload stats after sync
        await _loadSyncStats();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sync failed: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }
  
  Future<void> _clearOldData() async {
    try {
      await _offlineService.clearOldSyncedData(daysOld: 7);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Old synced data cleared successfully'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
        
        // Reload stats after cleanup
        await _loadSyncStats();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to clear old data: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Icon(
                  _getStatusIcon(),
                  color: _getStatusColor(),
                  size: 24,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Data Synchronization',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (widget.showManualSyncButton && _isOnline && _pendingDataCount > 0)
                  IconButton(
                    onPressed: _isSyncing ? null : _manualSync,
                    icon: _isSyncing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync),
                    tooltip: 'Manual sync',
                  ),
              ],
            ),
            
            const SizedBox(height: 16),
            
            // Status overview
            _buildStatusOverview(),
            
            // Detailed statistics
            if (widget.showDetailedStats) ...[
              const SizedBox(height: 16),
              _buildDetailedStats(),
            ],
            
            // Actions
            if (widget.showManualSyncButton) ...[
              const SizedBox(height: 16),
              _buildActions(),
            ],
          ],
        ),
      ),
    );
  }
  
  Widget _buildStatusOverview() {
    return Row(
      children: [
        Expanded(
          child: _buildStatusItem(
            icon: Icons.cloud_upload,
            label: 'Pending',
            value: '$_pendingDataCount',
            color: _pendingDataCount > 0 ? Colors.orange : Colors.grey,
          ),
        ),
        Expanded(
          child: _buildStatusItem(
            icon: Icons.sync,
            label: 'Status',
            value: _isSyncing ? 'Syncing...' : (_pendingDataCount > 0 ? 'Pending' : 'Up to date'),
            color: _isSyncing ? Colors.blue : (_pendingDataCount > 0 ? Colors.orange : Colors.green),
          ),
        ),
        Expanded(
          child: _buildStatusItem(
            icon: Icons.access_time,
            label: 'Last Sync',
            value: _formatLastSyncTime(),
            color: _lastSyncTime != null ? Colors.green : Colors.grey,
          ),
        ),
      ],
    );
  }
  
  Widget _buildStatusItem({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Column(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Colors.grey[600],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }
  
  Widget _buildDetailedStats() {
    if (_syncStats.isEmpty) {
      return const SizedBox.shrink();
    }
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Statistics',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _buildStatCard(
                title: 'Locations',
                total: _syncStats['totalLocations'] ?? 0,
                synced: _syncStats['syncedLocations'] ?? 0,
                pending: _syncStats['pendingLocations'] ?? 0,
                icon: Icons.location_on,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildStatCard(
                title: 'Events',
                total: _syncStats['totalEvents'] ?? 0,
                synced: _syncStats['syncedEvents'] ?? 0,
                pending: _syncStats['pendingEvents'] ?? 0,
                icon: Icons.event_note,
              ),
            ),
          ],
        ),
      ],
    );
  }
  
  Widget _buildStatCard({
    required String title,
    required int total,
    required int synced,
    required int pending,
    required IconData icon,
  }) {
    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Icon(icon, color: Colors.blue[600], size: 20),
            const SizedBox(height: 4),
            Text(
              title,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Total',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  '$total',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Synced',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  '$synced',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.green[600],
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Pending',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  '$pending',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: pending > 0 ? Colors.orange[600] : Colors.grey[600],
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildActions() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _isSyncing ? null : _manualSync,
            icon: const Icon(Icons.sync),
            label: Text(_isSyncing ? 'Syncing...' : 'Sync Now'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _isOnline ? Colors.blue : Colors.grey,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _clearOldData,
            icon: const Icon(Icons.cleaning_services),
            label: const Text('Clean Up'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.orange,
            ),
          ),
        ),
      ],
    );
  }
  
  String _formatLastSyncTime() {
    if (_lastSyncTime == null) return 'Never';
    
    final now = DateTime.now();
    final difference = now.difference(_lastSyncTime!);
    
    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inDays < 1) {
      return '${difference.inHours}h ago';
    } else {
      return DateFormat('MMM d, h:mm a').format(_lastSyncTime!);
    }
  }
  
  IconData _getStatusIcon() {
    if (_isSyncing) {
      return Icons.sync;
    } else if (_pendingDataCount > 0) {
      return Icons.cloud_upload;
    } else {
      return Icons.check_circle;
    }
  }
  
  Color _getStatusColor() {
    if (_isSyncing) {
      return Colors.blue;
    } else if (_pendingDataCount > 0) {
      return Colors.orange;
    } else {
      return Colors.green;
    }
  }
}
