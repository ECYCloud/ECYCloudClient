import 'package:flutter/widgets.dart';

import '../data/store/settings_store.dart';
import '../domain/platform/platform_service.dart';
import '../state/announcement_controller.dart';
import '../state/auth_controller.dart';
import '../state/connection_controller.dart';
import '../state/update_controller.dart';

class AppScope extends InheritedWidget {
  const AppScope({
    required this.auth,
    required this.connection,
    required this.announcements,
    required this.update,
    required this.platform,
    required this.settingsStore,
    required super.child,
    super.key,
  });

  final AuthController auth;
  final ConnectionController connection;
  final AnnouncementController announcements;
  final UpdateController update;
  final PlatformService platform;
  final SettingsStore settingsStore;

  static AppScope of(BuildContext context) {
    final AppScope? scope = context
        .dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope 未挂载');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      auth != oldWidget.auth ||
      connection != oldWidget.connection ||
      announcements != oldWidget.announcements ||
      update != oldWidget.update ||
      platform != oldWidget.platform;
}
