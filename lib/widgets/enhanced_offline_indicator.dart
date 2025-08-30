import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/network_connectivity_service.dart';
import '../services/offline_data_service.dart';

class EnhancedOfflineIndicator extends StatefulWidget {
  final VoidCallback? onRetry;
  final bool showRetryButton;
  final bool showSyncStatus;
  final bool showPendingData;
  
  const EnhancedOfflineIndicator({
    super.key,
    this.onRetry,
    this.showRetryButton = true,
    this.showSyncStatus = true,
    this.showPendingData = true,
  });

  @override
  State<EnhancedOfflineIndicator> createState() => _EnhancedOfflineIndicatorState();
}

class _EnhancedOfflineIndicatorState extends State<EnhancedOfflineIndicator> {
  final NetworkConnectivityService _networkService = NetworkConnectivityService();
  final OfflineDataService _offlineService = OfflineDataService();
  
  bool _isOnline = true;
  bool _isSyncing = false;
  int _pendingDataCount = 0;
  DateTime? _lastSyncTime;
  
  @override
  void initState() {
    super.initState();
    _checkConnectivity();
    _listenToConnectivityChanges();
    _listenToSyncStatus();
    _listenToPendingData();
    _listenToLastSync();
  }

  Future<void> _checkConnectivity() async {
    try {
      final isOnline = await _networkService.checkConnectivity();
      if (mounted) {
        setState(() {
          _isOnline = isOnline;
        });
      }
    } catch (e) {
      print('EnhancedOfflineIndicator: Error checking connectivity: $e');
    }
  }

  void _listenToConnectivityChanges() {
    _networkService.onConnectivityChanged.listen((isOnline) {
      if (mounted) {
        setState(() {
          _isOnline = isOnline;
        });
      }
    });
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

  @override
  Widget build(BuildContext context) {
    if (_isOnline && _pendingDataCount == 0) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: _getBackgroundColor(),
        border: Border(
          bottom: BorderSide(
            color: _getBorderColor(),
            width: 1,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Main status row
          Row(
            children: [
              Icon(
                _getStatusIcon(),
                color: _getIconColor(),
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _getStatusText(),
                  style: TextStyle(
                    color: _getTextColor(),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (widget.showRetryButton && widget.onRetry != null && !_isSyncing) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    _checkConnectivity();
                    widget.onRetry?.call();
                  },
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    'Retry',
                    style: TextStyle(
                      color: _getTextColor(),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
          
          // Additional status information
          if (widget.showSyncStatus || widget.showPendingData) ...[
            const SizedBox(height: 8),
            _buildAdditionalStatus(),
          ],
        ],
      ),
    );
  }
  
  Widget _buildAdditionalStatus() {
    final List<Widget> statusWidgets = [];
    
    // Show sync status
    if (widget.showSyncStatus && _isSyncing) {
      statusWidgets.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(_getTextColor()),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              'Syncing offline data...',
              style: TextStyle(
                color: _getTextColor(),
                fontSize: 12,
              ),
            ),
          ],
        ),
      );
    }
    
    // Show pending data count
    if (widget.showPendingData && _pendingDataCount > 0) {
      if (statusWidgets.isNotEmpty) {
        statusWidgets.add(const SizedBox(width: 16));
      }
      
      statusWidgets.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.data_usage,
              color: _getTextColor(),
              size: 12,
            ),
            const SizedBox(width: 4),
            Text(
              '$_pendingDataCount items pending sync',
              style: TextStyle(
                color: _getTextColor(),
                fontSize: 12,
              ),
            ),
          ],
        ),
      );
    }
    
    // Show last sync time
    if (widget.showSyncStatus && _lastSyncTime != null && !_isSyncing) {
      if (statusWidgets.isNotEmpty) {
        statusWidgets.add(const SizedBox(width: 16));
      }
      
      statusWidgets.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.sync,
              color: _getTextColor(),
              size: 12,
            ),
            const SizedBox(width: 4),
            Text(
              'Last sync: ${_formatLastSyncTime()}',
              style: TextStyle(
                color: _getTextColor(),
                fontSize: 12,
              ),
            ),
          ],
        ),
      );
    }
    
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: statusWidgets,
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
  
  // Helper methods for dynamic styling
  Color _getBackgroundColor() {
    if (_isSyncing) {
      return Colors.blue[100]!;
    } else if (_pendingDataCount > 0) {
      return Colors.orange[100]!;
    } else if (!_isOnline) {
      return Colors.red[100]!;
    } else {
      return Colors.green[100]!;
    }
  }
  
  Color _getBorderColor() {
    if (_isSyncing) {
      return Colors.blue[300]!;
    } else if (_pendingDataCount > 0) {
      return Colors.orange[300]!;
    } else if (!_isOnline) {
      return Colors.red[300]!;
    } else {
      return Colors.green[300]!;
    }
  }
  
  Color _getIconColor() {
    if (_isSyncing) {
      return Colors.blue[800]!;
    } else if (_pendingDataCount > 0) {
      return Colors.orange[800]!;
    } else if (!_isOnline) {
      return Colors.red[800]!;
    } else {
      return Colors.green[800]!;
    }
  }
  
  Color _getTextColor() {
    if (_isSyncing) {
      return Colors.blue[800]!;
    } else if (_pendingDataCount > 0) {
      return Colors.orange[800]!;
    } else if (!_isOnline) {
      return Colors.red[800]!;
    } else {
      return Colors.green[800]!;
    }
  }
  
  IconData _getStatusIcon() {
    if (_isSyncing) {
      return Icons.sync;
    } else if (_pendingDataCount > 0) {
      return Icons.data_usage;
    } else if (!_isOnline) {
      return Icons.wifi_off;
    } else {
      return Icons.check_circle;
    }
  }
  
  String _getStatusText() {
    if (_isSyncing) {
      return 'Synchronizing offline data...';
    } else if (_pendingDataCount > 0) {
      return 'You have $_pendingDataCount items waiting to sync';
    } else if (!_isOnline) {
      return 'You are currently offline. Some features may be limited.';
    } else {
      return 'All data is synchronized';
    }
  }

  @override
  void dispose() {
    _networkService.dispose();
    super.dispose();
  }
}
