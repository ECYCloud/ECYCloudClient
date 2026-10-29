import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ecycloud_client/platform/windows/named_pipe_client.dart';
import 'package:ecycloud_client/platform/windows/service_control.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('发送配置前拒绝冒充系统服务的管道', () async {
    final ServiceProbe service = await const ServiceControl('EventLog').probe();
    expect(service.running, isTrue);
    expect(service.processId, greaterThan(0));
    final String name =
        'ECYCloudSecurity-$pid-${DateTime.now().microsecondsSinceEpoch}';
    final Process server = await Process.start('pwsh', <String>[
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r'''
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$server = [IO.Pipes.NamedPipeServerStream]::new('__PIPE__', [IO.Pipes.PipeDirection]::InOut)
try {
  [Console]::WriteLine('ready')
  [Console]::Out.Flush()
  $server.WaitForConnection()
  try { [Console]::WriteLine($server.ReadByte()) }
  catch [System.IO.IOException] {
    $code = $_.Exception.GetBaseException().HResult -band 0xffff
    if ($code -notin 109, 232, 233) { throw }
    [Console]::WriteLine(-1)
  }
} finally { $server.Dispose() }
'''
          .replaceAll('__PIPE__', name),
    ]);
    final StreamIterator<String> lines = StreamIterator<String>(
      server.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    final Future<String> errors = server.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    try {
      expect(
        await lines.moveNext().timeout(const Duration(seconds: 15)),
        isTrue,
      );
      expect(lines.current, 'ready');
      await expectLater(
        NamedPipeClient('\\\\.\\pipe\\$name', 'EventLog').request(
          'kernel.start',
          <String, dynamic>{'config': 'private-config'},
        ),
        throwsA(
          isA<PipeException>().having(
            (PipeException e) => e.message,
            'message',
            contains('身份校验失败'),
          ),
        ),
      );
      final bool hasResult = await lines.moveNext().timeout(
        const Duration(seconds: 15),
      );
      expect(hasResult, isTrue, reason: hasResult ? null : await errors);
      expect(lines.current, '-1', reason: '假服务不能收到任何配置字节');
      expect(await server.exitCode, 0, reason: await errors);
    } finally {
      server.kill();
      await lines.cancel();
    }
  }, skip: !Platform.isWindows);
}
