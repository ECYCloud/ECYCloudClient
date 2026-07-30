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
    double size = value.toDouble();
    int unit = 0;

    while (size >= 1024 && unit < _units.length - 1) {
      size /= 1024;
      unit++;
    }

    return '${size.toStringAsFixed(unit == 0 ? 0 : 2)} ${_units[unit]}';
  }

  static String speed(num bytesPerSecond) => '${bytes(bytesPerSecond)}/s';

  static String date(DateTime? value) {
    if (value == null) {
      return '—';
    }
    return '${value.year}-${_two(value.month)}-${_two(value.day)}';
  }

  static String duration(Duration value) {
    final int hours = value.inHours;
    final int minutes = value.inMinutes % 60;
    final int seconds = value.inSeconds % 60;

    return hours > 0
        ? '$hours:${_two(minutes)}:${_two(seconds)}'
        : '${_two(minutes)}:${_two(seconds)}';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}
