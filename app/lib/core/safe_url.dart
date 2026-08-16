class SafeUrl {
  SafeUrl._();

  static bool canOpen(String url) => _schemeIn(url, _open);

  static bool canOpenLink(String url) => _schemeIn(url, _link);

  static bool canLoad(String url) => _schemeIn(url, _web);

  static const Set<String> _web = <String>{'http', 'https'};
  static const Set<String> _link = <String>{'http', 'https', 'mailto'};
  // weixin / alipay(s) 是微信与支付宝注册的 scheme，应用内唤起付款必须放行
  static const Set<String> _open = <String>{
    'http',
    'https',
    'mailto',
    'tg',
    'weixin',
    'alipay',
    'alipays',
  };

  static bool _schemeIn(String url, Set<String> schemes) {
    final Uri? uri = Uri.tryParse(url.trim());
    if (uri == null || uri.scheme.isEmpty) {
      return false;
    }
    return schemes.contains(uri.scheme.toLowerCase());
  }
}
