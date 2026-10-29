import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ecycloud_client/core/logger.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final Directory base = Directory('build/test-data')
    ..createSync(recursive: true);
  final Directory sandbox = base.createTempSync('client-').absolute;
  final Map<String, String> env = Platform.environment;
  final String userData = Platform.isWindows
      ? '${env['APPDATA']}/ECYCloud'
      : Platform.isMacOS
      ? '${env['HOME']}/Library/Application Support/ECYCloud'
      : '${env['XDG_CONFIG_HOME']?.isNotEmpty == true ? env['XDG_CONFIG_HOME'] : '${env['HOME']}/.config'}/ECYCloud';
  final IOOverrides? previous = IOOverrides.current;
  setUpAll(() => IOOverrides.global = _ClientTestFiles(userData, sandbox.path));
  tearDownAll(() async {
    await Logger.instance.dispose();
    IOOverrides.global = previous;
    sandbox.deleteSync(recursive: true);
  });
  await testMain();
}

final class _ClientTestFiles extends IOOverrides {
  _ClientTestFiles(String source, this.target) : source = _normalize(source);

  final String source;
  final String target;

  static String _normalize(String path) {
    final String result = path.replaceAll('\\', '/');
    return Platform.isWindows ? result.toLowerCase() : result;
  }

  String _path(String path) {
    final String normalized = _normalize(path);
    if (normalized == source || normalized.startsWith('$source/')) {
      return '$target${path.substring(source.length)}';
    }
    return path;
  }

  @override
  Directory createDirectory(String path) => super.createDirectory(_path(path));

  @override
  File createFile(String path) => super.createFile(_path(path));

  @override
  Link createLink(String path) => super.createLink(_path(path));
}
