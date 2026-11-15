import 'dart:isolate';
import 'dart:typed_data';

class TextLineIndex {
  TextLineIndex._(this._text, this._starts, this._ends, this.widest);

  static const int maxLineChars = 10000;
  static const int _isolateThreshold = 256 * 1024;
  static const int _widestCount = 8;

  final String _text;
  final Int32List _starts;
  final Int32List _ends;
  final List<int> widest;

  int get length => _starts.length;

  String operator [](int index) {
    final int start = _starts[index];
    int end = _ends[index];
    if (end - start <= maxLineChars) {
      return _text.substring(start, end);
    }
    end = start + maxLineChars;
    if (_isLeadSurrogate(_text.codeUnitAt(end - 1))) {
      end--;
    }
    return '${_text.substring(start, end)}…';
  }

  static Future<TextLineIndex> build(String text) async {
    final _Scan scan = text.length < _isolateThreshold
        ? _scan(text)
        : await Isolate.run(() => _scan(text));
    return TextLineIndex._(text, scan.starts, scan.ends, scan.widest);
  }

  static bool _isLeadSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

  // 断行规则与 LineSplitter 一致：\n、\r\n、\r 均为行尾，末尾行尾不再多出空行
  static _Scan _scan(String text) {
    final List<int> starts = <int>[];
    final List<int> ends = <int>[];
    final List<int> widest = <int>[];
    void add(int start, int end) {
      final int line = starts.length;
      starts.add(start);
      ends.add(end);
      final int span = end - start;
      if (widest.length == _widestCount) {
        int shortest = 0;
        for (int i = 1; i < widest.length; i++) {
          if (_spanOf(starts, ends, widest[i]) <
              _spanOf(starts, ends, widest[shortest])) {
            shortest = i;
          }
        }
        if (span > _spanOf(starts, ends, widest[shortest])) {
          widest[shortest] = line;
        }
      } else {
        widest.add(line);
      }
    }

    int start = 0;
    final int length = text.length;
    for (int i = 0; i < length; i++) {
      final int unit = text.codeUnitAt(i);
      if (unit == 0x0A) {
        add(start, i);
        start = i + 1;
      } else if (unit == 0x0D) {
        add(start, i);
        if (i + 1 < length && text.codeUnitAt(i + 1) == 0x0A) {
          i++;
        }
        start = i + 1;
      }
    }
    if (start < length) {
      add(start, length);
    }
    return _Scan(Int32List.fromList(starts), Int32List.fromList(ends), widest);
  }

  static int _spanOf(List<int> starts, List<int> ends, int line) =>
      ends[line] - starts[line];
}

class _Scan {
  const _Scan(this.starts, this.ends, this.widest);

  final Int32List starts;
  final Int32List ends;
  final List<int> widest;
}
