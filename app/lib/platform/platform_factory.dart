import 'dart:io';

import '../domain/kernel/kernel_controller.dart';
import '../domain/platform/platform_service.dart';
import 'windows/service_kernel_controller.dart';
import 'windows/windows_platform_service.dart';

class PlatformFactory {
  PlatformFactory._();

  static PlatformService createPlatformService() {
    if (Platform.isWindows) {
      return WindowsPlatformService();
    }
    throw UnsupportedError('${Platform.operatingSystem} 平台尚未实现');
  }

  static KernelController createKernelController() {
    if (Platform.isWindows) {
      return ServiceKernelController.production();
    }
    throw UnsupportedError('${Platform.operatingSystem} 平台尚未实现');
  }
}
