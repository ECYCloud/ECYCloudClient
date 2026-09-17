import 'package:flutter/widgets.dart';

class ShellNavigator extends InheritedWidget {
  const ShellNavigator({required this.goTo, required super.child, super.key});

  static const int homeTab = 0;
  static const int nodesTab = 1;
  static const int shopTab = 2;
  static const int ticketsTab = 3;
  static const int inviteTab = 4;
  static const int unlockTab = 5;

  final void Function(int index) goTo;

  // 弹窗的 context 不在本 InheritedWidget 子树内，靠 Shell 注册的宿主回调切页
  static void Function(int index)? _hostGoTo;
  static void Function(String tab)? _shopTabHandler;
  static String? _pendingShopTab;

  static void bindHost(void Function(int index) goTo) {
    _hostGoTo = goTo;
  }

  static void unbindHost(void Function(int index) goTo) {
    // 实例方法 tear-off 每次求值都是新闭包，identical 恒为 false
    if (_hostGoTo == goTo) {
      _hostGoTo = null;
    }
  }

  static void bindShopTab(void Function(String tab) handler) {
    _shopTabHandler = handler;
  }

  static void unbindShopTab(void Function(String tab) handler) {
    // 实例方法 tear-off 每次求值都是新闭包，identical 恒为 false
    if (_shopTabHandler == handler) {
      _shopTabHandler = null;
    }
  }

  static String? takePendingShopTab() {
    final String? tab = _pendingShopTab;
    _pendingShopTab = null;
    return tab;
  }

  static ShellNavigator? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellNavigator>();

  static void go(BuildContext context, int index) {
    final ShellNavigator? nav = maybeOf(context);
    if (nav != null) {
      nav.goTo(index);
      return;
    }
    _hostGoTo?.call(index);
  }

  static void openShopTraffic(BuildContext context) {
    const String tab = 'traffic_package';
    go(context, shopTab);
    final void Function(String)? handler = _shopTabHandler;
    if (handler != null) {
      handler(tab);
    } else {
      _pendingShopTab = tab;
    }
  }

  static bool openTab(BuildContext context, int index) {
    final void Function(int)? goTo = maybeOf(context)?.goTo ?? _hostGoTo;
    if (goTo == null) {
      return false;
    }
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route is PopupRoute) {
      Navigator.of(context).pop();
    }
    goTo(index);
    return true;
  }

  @override
  bool updateShouldNotify(ShellNavigator oldWidget) => goTo != oldWidget.goTo;
}
