import 'dart:io';

import '../domain/kernel/kernel_controller.dart';
import '../domain/platform/platform_service.dart';
import 'android/android_platform_service.dart';
import 'android/vpn_channel.dart';
import 'linux/linux_platform_service.dart';
import 'macos/macos_platform_service.dart';
import 'service/service_kernel_controller.dart';
import 'unix/helper_client.dart';
import 'windows/service_pipe.dart';
import 'windows/windows_platform_service.dart';

class PlatformFactory {
  PlatformFactory._();

  static const String _linuxHelperHint =
      '后台服务未运行，执行 sudo systemctl start ecycloud-helper 或重装客户端';

  static PlatformService createPlatformService() {
    if (Platform.isWindows) {
      return WindowsPlatformService();
    }
    if (Platform.isMacOS) {
      return MacosPlatformService.production();
    }
    if (Platform.isLinux) {
      return LinuxPlatformService();
    }
    if (Platform.isAndroid) {
      return AndroidPlatformService();
    }
    throw UnsupportedError('${Platform.operatingSystem} 平台尚未实现');
  }

  static KernelController createKernelController() {
    if (Platform.isWindows) {
      return ServiceKernelController(
        transport: ServicePipe.production(),
        tunProbeCommand: 'wintun.ensure',
      );
    }
    if (Platform.isMacOS) {
      return ServiceKernelController(
        transport: const HelperClient(
          HelperClient.defaultSocketPath,
          MacosPlatformService.helperMissingHint,
        ),
        tunProbeCommand: 'tun.ensure',
      );
    }
    if (Platform.isLinux) {
      return ServiceKernelController(
        transport: const HelperClient(
          HelperClient.defaultSocketPath,
          _linuxHelperHint,
        ),
        tunProbeCommand: 'tun.ensure',
      );
    }
    // libbox 随客户端一起编译进 APK，换内核只能整包更新
    if (Platform.isAndroid) {
      return ServiceKernelController(
        transport: const VpnChannel(),
        tunProbeCommand: 'tun.ensure',
        upgradable: false,
        logFromClashApi: true,
      );
    }
    throw UnsupportedError('${Platform.operatingSystem} 平台尚未实现');
  }
}
