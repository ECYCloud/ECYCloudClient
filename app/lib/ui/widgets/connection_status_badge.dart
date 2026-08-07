import 'package:flutter/material.dart';

import '../../state/connection_controller.dart';
import '../theme.dart';

class ConnectionStatusVisual {
  const ConnectionStatusVisual({
    required this.color,
    required this.icon,
    required this.label,
  });

  final Color color;
  final IconData icon;
  final String label;

  static ConnectionStatusVisual of(
    ConnectionPhase phase,
    ColorScheme scheme, {
    String? failedLabel,
  }) => switch (phase) {
    ConnectionPhase.connected => const ConnectionStatusVisual(
      color: AppTheme.success,
      icon: Icons.shield,
      label: '已连接',
    ),
    ConnectionPhase.connecting => const ConnectionStatusVisual(
      color: AppTheme.warning,
      icon: Icons.sync,
      label: '正在连接',
    ),
    ConnectionPhase.disconnecting => const ConnectionStatusVisual(
      color: AppTheme.warning,
      icon: Icons.sync,
      label: '正在断开连接',
    ),
    ConnectionPhase.failed => ConnectionStatusVisual(
      color: AppTheme.danger,
      icon: Icons.shield_outlined,
      label: failedLabel ?? '连接失败',
    ),
    ConnectionPhase.disconnected => ConnectionStatusVisual(
      color: scheme.outline,
      icon: Icons.shield_outlined,
      label: '未连接',
    ),
  };
}

class ConnectionStatusBadge extends StatefulWidget {
  const ConnectionStatusBadge({
    super.key,
    required this.icon,
    required this.color,
    required this.spinning,
    this.size = 50,
    double? iconSize,
  }) : iconSize = iconSize ?? size * 24 / 50;

  final IconData icon;
  final Color color;
  final bool spinning;
  final double size;
  final double iconSize;

  @override
  State<ConnectionStatusBadge> createState() => _ConnectionStatusBadgeState();
}

class _ConnectionStatusBadgeState extends State<ConnectionStatusBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(ConnectionStatusBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _syncAnimation() {
    if (widget.spinning) {
      if (!_controller.isAnimating) {
        _controller.repeat();
      }
    } else if (_controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget icon = Icon(
      widget.icon,
      size: widget.iconSize,
      color: widget.color,
    );

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      height: widget.size,
      width: widget.size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: widget.color.withValues(alpha: 0.12),
        border: Border.all(color: widget.color.withValues(alpha: 0.22)),
      ),
      child: Center(
        child: widget.spinning
            ? RotationTransition(turns: _controller, child: icon)
            : icon,
      ),
    );
  }
}
