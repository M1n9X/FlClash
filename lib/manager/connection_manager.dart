import 'dart:async';
import 'dart:math';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ConnectionManager extends ConsumerStatefulWidget {
  final Widget child;

  const ConnectionManager({super.key, required this.child});

  @override
  ConsumerState<ConnectionManager> createState() => _ConnectionManagerState();
}

class _ConnectionManagerState extends ConsumerState<ConnectionManager> {
  final _nodeHealthChecker = NodeHealthChecker();
  final _failoverHandler = FailoverHandler();
  final _connectionPool = ConnectionPool();
  final _reconnectionManager = ReconnectionManager();

  @override
  void initState() {
    super.initState();

    // Listen to network changes - 注释掉未定义的provider
    // ref.listenManual(
    //   connectivityResultProvider,
    //   (prev, next) {
    //     if (prev != next) {
    //       _handleNetworkChange(next);
    //     }
    //   },
    // );

    // Listen to group changes to maintain multiple connections
    ref.listenManual(
      groupsProvider,
      (prev, next) {
        if (prev != next) {
          _maintainMultipleConnections(next as List<Group>);
        }
      },
    );

    // Initialize all managers
    _failoverHandler.init();
    _connectionPool.startMonitoring();
  }

  @override
  void dispose() {
    _nodeHealthChecker.dispose();
    _failoverHandler.dispose();
    _connectionPool.closeAllConnections();
    _reconnectionManager.dispose();
    super.dispose();
  }

  void _handleNetworkChange(dynamic networkResult) {
    // When network changes, re-check node health and potentially failover
    _nodeHealthChecker.checkAllNodesHealth();

    // Also restart connection pool monitoring after network change
    _connectionPool.startMonitoring();
  }

  void _maintainMultipleConnections(List<Group> groups) {
    // Maintain multiple connections for selector and URLTest groups
    for (final group in groups) {
      if (group.type == GroupType.Selector || group.type == GroupType.URLTest) {
        final nodeNames = group.all.map((proxy) => proxy.name).toList();
        _connectionPool.maintainMultipleConnections(group.name, nodeNames);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

class NodeHealthChecker {
  Timer? _healthCheckTimer;
  String? _currentTestUrl;

  // Map to store node health status
  final Map<String, NodeHealthStatus> _nodeHealthStatus = {};

  void startHealthMonitoring(String testUrl) {
    _currentTestUrl = testUrl;
    // Check node health every 30 seconds
    _healthCheckTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      checkAllNodesHealth();
    });
  }

  void stopHealthMonitoring() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
  }

  Future<void> checkAllNodesHealth() async {
    try {
      final groups = await coreController.getProxiesGroups(
        selectedMap: {},
        sortType: ProxiesSortType.none,
        delayMap: {},
        defaultTestUrl: _currentTestUrl ?? '',
      );

      for (final group in groups) {
        if (group.type == GroupType.Selector || group.type == GroupType.URLTest) {
          await _checkGroupHealth(group);
        }
      }
    } catch (e) {
      commonPrint.log('Error checking node health: $e', logLevel: LogLevel.warning);
    }
  }

  Future<void> _checkGroupHealth(Group group) async {
    for (final proxy in group.all) {
      if (proxy.name.isNotEmpty) { // 用proxy.name是否为空来替代isEnable
        final delay = await _testNodeHealth(proxy.name, _currentTestUrl ?? '');
        _nodeHealthStatus[proxy.name] = NodeHealthStatus(
          name: proxy.name,
          delay: delay,
          isHealthy: delay.value != -1 && delay.value! < 3000, // Consider healthy if delay < 3 seconds
          lastChecked: DateTime.now(),
        );
      }
    }
  }

  Future<Delay> _testNodeHealth(String nodeName, String testUrl) async {
    try {
      return await coreController.getDelay(testUrl, nodeName);
    } catch (e) {
      return Delay(name: nodeName, url: testUrl, value: -1);
    }
  }

  List<NodeHealthStatus> getHealthyNodes(String groupName) {
    final groups = globalState.appController.getCurrentGroups();
    final group = groups.firstWhere((g) => g.name == groupName, orElse: () => Group.empty());

    return group.all
        .where((proxy) => _nodeHealthStatus[proxy.name]?.isHealthy == true)
        .map((proxy) => _nodeHealthStatus[proxy.name]!)
        .toList();
  }

  NodeHealthStatus? getBestNode(String groupName) {
    final healthyNodes = getHealthyNodes(groupName);
    if (healthyNodes.isEmpty) return null;

    return healthyNodes.reduce((a, b) => a.delay.value! < b.delay.value! ? a : b);
  }

  void dispose() {
    _healthCheckTimer?.cancel();
  }
}

class NodeHealthStatus {
  final String name;
  final Delay delay;
  final bool isHealthy;
  final DateTime lastChecked;

  NodeHealthStatus({
    required this.name,
    required this.delay,
    required this.isHealthy,
    required this.lastChecked,
  });
}

class FailoverHandler {
  Timer? _failoverTimer;
  final _nodeHealthChecker = NodeHealthChecker();
  final _reconnectionManager = ReconnectionManager();

  void init() {
    // Start monitoring for potential node failures
    _startMonitoring();
  }

  void _startMonitoring() {
    _failoverTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      _checkForFailover();
    });
  }

  void _checkForFailover() async {
    final currentGroupName = globalState.appController.getCurrentGroupName();
    if (currentGroupName == null) return;

    final groups = globalState.appController.getCurrentGroups();
    final currentGroup = groups.firstWhere(
      (g) => g.name == currentGroupName,
      orElse: () => Group.empty(),
    );

    if (currentGroup.type != GroupType.Selector && currentGroup.type != GroupType.URLTest) {
      return; // Only handle selector and URLTest groups
    }

    // Get currently selected node
    final currentSelectedNode = globalState.appController.getSelectedProxyName(currentGroupName);
    if (currentSelectedNode == null) return;

    // Check if current node is healthy
    final currentHealth = await _checkSingleNodeHealth(currentSelectedNode, currentGroupName);

    if (!currentHealth) {
      // Current node is unhealthy, initiate failover
      await _performFailover(currentGroupName, currentSelectedNode);
    }
  }

  Future<bool> _checkSingleNodeHealth(String nodeName, String groupName) async {
    try {
      final delay = await coreController.getDelay(
        globalState.appController.getRealTestUrl(null),
        nodeName,
      );

      return delay.value != -1 && delay.value! < 5000; // Healthy if delay < 5 seconds
    } catch (e) {
      return false;
    }
  }

  Future<void> _performFailover(String groupName, String failedNode) async {
    commonPrint.log('Initiating failover from node: $failedNode in group: $groupName');

    try {
      // Get list of alternative healthy nodes in the group
      final groups = globalState.appController.getCurrentGroups();
      final currentGroup = groups.firstWhere(
        (g) => g.name == groupName,
        orElse: () => Group.empty(),
      );

      // Find a healthy alternative node
      String? newProxyName;
      for (final proxy in currentGroup.all) {
        if (proxy.name != failedNode) {
          final isHealthy = await _checkSingleNodeHealth(proxy.name, groupName);
          if (isHealthy) {
            newProxyName = proxy.name;
            break;
          }
        }
      }

      if (newProxyName != null) {
        // Switch to the healthy alternative
        await globalState.appController.changeProxy(
          groupName: groupName,
          proxyName: newProxyName,
        );

        globalState.appController.updateCurrentSelectedMap(groupName, newProxyName);

        // Schedule reconnection to the original failed node for future availability
        _reconnectionManager.scheduleReconnection(groupName, failedNode);

        commonPrint.log('Successfully failed over to node: $newProxyName');
      } else {
        commonPrint.log('No healthy alternatives found for group: $groupName',
            logLevel: LogLevel.warning);
        // Even if no alternatives are available, still schedule reconnection to the failed node
        _reconnectionManager.scheduleReconnection(groupName, failedNode);
      }
    } catch (e) {
      commonPrint.log('Error during failover: $e', logLevel: LogLevel.warning);
      // If failover fails, still try to schedule reconnection
      _reconnectionManager.scheduleReconnection(groupName, failedNode);
    }
  }

  void dispose() {
    _failoverTimer?.cancel();
    _reconnectionManager.dispose();
  }
}

// Connection pool to maintain multiple active connections
class ConnectionPool {
  final Map<String, Map<String, ConnectionStatus>> _connectionPool = {};
  final Map<String, String> _activeConnections = {};
  Timer? _monitorTimer;

  void startMonitoring() {
    // Monitor connections every 15 seconds
    _monitorTimer = Timer.periodic(const Duration(seconds: 15), (timer) {
      _monitorConnections();
    });
  }

  void _monitorConnections() {
    _connectionPool.forEach((groupName, connections) {
      for (final entry in connections.entries) {
        final nodeName = entry.key;
        final status = entry.value;

        if (status.isConnected) {
          // Test if the connection is still alive
          _checkConnectionStatus(groupName, nodeName, status);
        }
      }
    });
  }

  void _checkConnectionStatus(String groupName, String nodeName, ConnectionStatus status) {
    // Run the async check in a separate future
    Future<void>.microtask(() async {
      try {
        final delay = await coreController.getDelay(
          globalState.appController.getRealTestUrl(null),
          nodeName,
        );

        if (delay.value == -1) {
          // Connection is no longer active
          _connectionPool[groupName]![nodeName] = ConnectionStatus(
            name: nodeName,
            isConnected: false,
            lastConnected: status.lastConnected,
          );
        }
      } catch (e) {
        // If there's an error checking the connection, mark it as disconnected
        _connectionPool[groupName]![nodeName] = ConnectionStatus(
          name: nodeName,
          isConnected: false,
          lastConnected: status.lastConnected,
        );
      }
    });
  }

  Future<void> maintainMultipleConnections(String groupName, List<String> nodeNames) async {
    if (!_connectionPool.containsKey(groupName)) {
      _connectionPool[groupName] = {};
    }

    final groupConnections = _connectionPool[groupName]!;

    // Start maintaining connections to healthy nodes
    for (final nodeName in nodeNames) {
      if (!groupConnections.containsKey(nodeName)) {
        groupConnections[nodeName] = ConnectionStatus(
          name: nodeName,
          isConnected: false,
          lastConnected: null,
        );
      }
    }

    // Attempt to establish connections to healthy nodes (up to 3)
    int connectedCount = 0;
    for (final entry in groupConnections.entries) {
      if (connectedCount >= 3) break; // Limit to 3 concurrent connections

      final nodeName = entry.key;
      final status = entry.value;

      if (!status.isConnected) {
        // Try to establish connection to this node
        final success = await _establishConnection(groupName, nodeName);
        if (success) {
          connectedCount++;
          _activeConnections[groupName] = nodeName;
        }
      }
    }
  }

  Future<bool> _establishConnection(String groupName, String nodeName) async {
    try {
      // Test the connection
      final delay = await coreController.getDelay(
        globalState.appController.getRealTestUrl(null),
        nodeName,
      );

      if (delay.value != -1) {
        _connectionPool[groupName]![nodeName] = ConnectionStatus(
          name: nodeName,
          isConnected: true,
          lastConnected: DateTime.now(),
        );
        return true;
      }
    } catch (e) {
      commonPrint.log('Error establishing connection to $nodeName: $e',
          logLevel: LogLevel.warning);
    }
    return false;
  }

  Future<String?> getBestAvailableConnection(String groupName) async {
    if (!_connectionPool.containsKey(groupName)) return null;

    final groupConnections = _connectionPool[groupName]!;
    final connectedConnections = groupConnections.entries
        .where((entry) => entry.value.isConnected)
        .toList();

    if (connectedConnections.isEmpty) return null;

    // Create futures for all delay checks
    final delayResults = <Map<String, int?>>[]; // List of maps with nodeName -> delay
    final futures = <Future<void>>[];

    for (final entry in connectedConnections) {
      futures.add(_checkConnectionDelay(entry.key).then((delay) {
        if (delay != null) {
          delayResults.add({entry.key: delay});
        }
      }));
    }

    // Wait for all checks to complete
    await Future.wait(futures, eagerError: true);

    // Find the best connection from the results
    String? bestConnection;
    int bestDelay = 99999; // Initialize with a high value

    for (final result in delayResults) {
      result.forEach((nodeName, delay) {
        if (delay != null && delay < bestDelay) {
          bestDelay = delay;
          bestConnection = nodeName;
        }
      });
    }

    return bestConnection ?? connectedConnections.first.key;
  }

  Future<int?> _checkConnectionDelay(String nodeName) async {
    try {
      final delayFuture = coreController.getDelay(
        globalState.appController.getRealTestUrl(null),
        nodeName,
      );

      final delay = await delayFuture.timeout(const Duration(seconds: 3));

      if (delay.value != null) {
        return delay.value!;
      }
    } catch (e) {
      // Skip this connection if delay test fails
    }
    return null;
  }

  void closeAllConnections() {
    _connectionPool.clear();
    _activeConnections.clear();
    _monitorTimer?.cancel();
  }
}

class ConnectionStatus {
  final String name;
  final bool isConnected;
  final DateTime? lastConnected;

  ConnectionStatus({
    required this.name,
    required this.isConnected,
    this.lastConnected,
  });
}

// Reconnection manager with exponential backoff
class ReconnectionManager {
  final Map<String, ReconnectionAttempt> _reconnectionAttempts = {};

  Future<void> scheduleReconnection(String groupName, String failedNode, {Duration? initialDelay}) async {
    final delay = initialDelay ?? _calculateExponentialBackoff(groupName);

    // Cancel any existing reconnection attempts for this group
    _cancelReconnection(groupName);

    _reconnectionAttempts[groupName] = ReconnectionAttempt(
      timer: Timer(delay, () => _attemptReconnect(groupName, failedNode)),
      attemptCount: _getAttemptCount(groupName) + 1,
      scheduledAt: DateTime.now(),
      nextDelay: delay,
    );

    commonPrint.log('Scheduled reconnection attempt for group $groupName in ${delay.inSeconds} seconds');
  }

  void _cancelReconnection(String groupName) {
    _reconnectionAttempts[groupName]?.timer.cancel();
    _reconnectionAttempts.remove(groupName);
  }

  Future<void> _attemptReconnect(String groupName, String failedNode) async {
    try {
      // Test if the node is back online
      final delayResult = await coreController.getDelay(
        globalState.appController.getRealTestUrl(null),
        failedNode,
      );

      if (delayResult.value != -1 && delayResult.value! < 3000) {
        // Node is back online, switch back to it if it's still the selected node or if we want to reconnect to it
        final currentSelectedNode = globalState.appController.getSelectedProxyName(groupName);
        if (currentSelectedNode == failedNode) {
          // Only reconnect if the current node is the one that failed
          await globalState.appController.changeProxy(
            groupName: groupName,
            proxyName: failedNode,
          );

          globalState.appController.updateCurrentSelectedMap(groupName, failedNode);

          _reconnectionAttempts.remove(groupName);
          commonPrint.log('Successfully reconnected to node: $failedNode');
        } else {
          // The node is back online but we're already on a different node
          // We can add it back to the pool of available nodes
          _reconnectionAttempts.remove(groupName);
          commonPrint.log('Node $failedNode is back online but using different node');
        }
      } else {
        // Node still unavailable, schedule another attempt
        await scheduleReconnection(groupName, failedNode);
      }
    } catch (e) {
      // Node still unavailable, schedule another attempt
      commonPrint.log('Reconnection attempt failed: $e', logLevel: LogLevel.warning);
      await scheduleReconnection(groupName, failedNode);
    }
  }

  Duration _calculateExponentialBackoff(String groupName) {
    final attemptCount = _getAttemptCount(groupName);
    final baseDelay = 5; // Start with 5 seconds
    final maxDelay = 600; // Max 10 minutes

    // Exponential backoff: baseDelay * (2 ^ attemptCount), capped at maxDelay
    // This gives: 5s, 10s, 20s, 40s, 80s, 160s, 320s, 600s(max), 600s, ...
    final delaySeconds = min(maxDelay, baseDelay * pow(2, attemptCount));
    return Duration(seconds: delaySeconds.toInt());
  }

  int _getAttemptCount(String groupName) {
    return _reconnectionAttempts[groupName]?.attemptCount ?? 0;
  }

  void resetReconnectionAttempts(String groupName) {
    _cancelReconnection(groupName);
  }

  void dispose() {
    _reconnectionAttempts.values.forEach((attempt) => attempt.timer.cancel());
    _reconnectionAttempts.clear();
  }
}

class ReconnectionAttempt {
  final Timer timer;
  final int attemptCount;
  final DateTime scheduledAt;
  final Duration nextDelay;

  ReconnectionAttempt({
    required this.timer,
    required this.attemptCount,
    required this.scheduledAt,
    required this.nextDelay,
  });
}