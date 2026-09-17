import '../l10n/l10n.dart';

class Format {
  Format._();

  static const List<String> _units = <String>[
    'B',
    'KB',
    'MB',
    'GB',
    'TB',
    'PB',
  ];

  static String bytes(num value) {
    final bool negative = value < 0;
    double size = value.abs().toDouble();
    int unit = 0;

    while (size >= 1024 && unit < _units.length - 1) {
      size /= 1024;
      unit++;
    }

    final String amount = size.toStringAsFixed(unit == 0 ? 0 : 2);
    return '${negative ? '-' : ''}$amount ${_units[unit]}';
  }

  static String speed(num bytesPerSecond) => '${bytes(bytesPerSecond)}/s';

  static String speedSi(num bytesPerSecond) =>
      '${(bytesPerSecond / 1000 / 1000).toStringAsFixed(1)} MB/s';

  static String number(num value) {
    final double amount = value.toDouble();
    return amount == amount.roundToDouble()
        ? amount.toStringAsFixed(0)
        : '$amount';
  }

  static String date(DateTime? value) {
    if (value == null) {
      return '—';
    }
    return '${value.year}-${_two(value.month)}-${_two(value.day)}';
  }

  static String clock(DateTime value) =>
      '${_two(value.hour)}:${_two(value.minute)}:${_two(value.second)}';

  static String duration(Duration value) {
    final int hours = value.inHours;
    final int minutes = value.inMinutes % 60;
    final int seconds = value.inSeconds % 60;

    return hours > 0
        ? '$hours:${_two(minutes)}:${_two(seconds)}'
        : '${_two(minutes)}:${_two(seconds)}';
  }

  static String elapsed(Duration value) {
    int seconds = value.inSeconds;
    if (seconds < 0) {
      seconds = 0;
    }
    final int years = seconds ~/ (365 * 24 * 3600);
    seconds %= 365 * 24 * 3600;
    final int months = seconds ~/ (30 * 24 * 3600);
    seconds %= 30 * 24 * 3600;
    final int days = seconds ~/ (24 * 3600);
    seconds %= 24 * 3600;
    final int hours = seconds ~/ 3600;
    seconds %= 3600;
    final int minutes = seconds ~/ 60;
    seconds %= 60;

    final List<String> parts = <String>[
      if (years > 0) L10n.t('{0}年', <Object>[years]),
      if (months > 0) L10n.t('{0}个月', <Object>[months]),
      if (days > 0) L10n.t('{0}天', <Object>[days]),
      if (hours > 0) L10n.t('{0}小时', <Object>[hours]),
      if (minutes > 0) L10n.t('{0}分钟', <Object>[minutes]),
      if (seconds > 0 || years + months + days + hours + minutes == 0)
        L10n.t('{0}秒', <Object>[seconds]),
    ];
    return parts.join(' ');
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}
