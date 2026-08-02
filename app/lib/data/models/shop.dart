/// 面板金额为 `number_format` 文案，千位分隔符需去掉后再比较
double parseAmount(String value) =>
    double.tryParse(value.replaceAll(',', '')) ?? 0;

class ShopCountdown {
  const ShopCountdown({required this.label, required this.endsAt});

  final String label;
  final DateTime endsAt;

  factory ShopCountdown.fromJson(Map<String, dynamic> json) => ShopCountdown(
    label: json['label'] as String? ?? '',
    endsAt: DateTime.fromMillisecondsSinceEpoch(
      ((json['end'] as num?)?.toInt() ?? 0) * 1000,
    ),
  );
}

class ShopProduct {
  const ShopProduct({
    required this.id,
    required this.name,
    required this.type,
    required this.price,
    required this.basePrice,
    required this.hasLimitedSale,
    required this.stock,
    required this.inStock,
    required this.purchaseLimit,
    required this.newUserDaysLimit,
    required this.minRegistrationDays,
    required this.countdowns,
    required this.bandwidth,
    required this.userClass,
    required this.classExpire,
    required this.speedLimit,
    required this.connector,
    required this.autoRenew,
    required this.contentExtra,
    required this.description,
  });

  final int id;
  final String name;
  final String type;
  final String price;
  final String basePrice;
  final bool hasLimitedSale;
  final String stock;
  final bool inStock;
  final int purchaseLimit;
  final int newUserDaysLimit;
  final int minRegistrationDays;
  final List<ShopCountdown> countdowns;
  final double bandwidth;
  final int userClass;
  final int classExpire;
  final double speedLimit;
  final int connector;
  final int autoRenew;
  final List<String> contentExtra;
  final String description;

  bool get isPlan => type == 'plan';

  bool get isTrafficPackage => type == 'traffic_package';

  bool get isCardKey => type == 'card_key';

  double get amount => parseAmount(price);

  factory ShopProduct.fromJson(Map<String, dynamic> json) {
    final Object? countdowns = json['countdowns'];
    final Object? extra = json['content_extra'];

    return ShopProduct(
      id: (json['id'] as num).toInt(),
      name: json['name'] as String? ?? '',
      type: json['type'] as String? ?? '',
      price: json['price'] as String? ?? '0.00',
      basePrice: json['base_price'] as String? ?? '0.00',
      hasLimitedSale: json['has_limited_sale'] as bool? ?? false,
      stock: json['stock'] as String? ?? '',
      inStock: json['in_stock'] as bool? ?? false,
      purchaseLimit: (json['purchase_limit'] as num?)?.toInt() ?? 0,
      newUserDaysLimit: (json['new_user_days_limit'] as num?)?.toInt() ?? 0,
      minRegistrationDays:
          (json['min_registration_days'] as num?)?.toInt() ?? 0,
      countdowns: <ShopCountdown>[
        if (countdowns is List)
          for (final Object? item in countdowns)
            if (item is Map<String, dynamic>) ShopCountdown.fromJson(item),
      ],
      bandwidth: (json['bandwidth'] as num?)?.toDouble() ?? 0,
      userClass: (json['class'] as num?)?.toInt() ?? 0,
      classExpire: (json['class_expire'] as num?)?.toInt() ?? 0,
      speedLimit: (json['speedlimit'] as num?)?.toDouble() ?? 0,
      connector: (json['connector'] as num?)?.toInt() ?? 0,
      autoRenew: (json['auto_renew'] as num?)?.toInt() ?? 0,
      contentExtra: <String>[
        if (extra is List)
          for (final Object? item in extra)
            if (item is String && item.isNotEmpty) item,
      ],
      description: json['description'] as String? ?? '',
    );
  }
}

class ShopCatalog {
  const ShopCatalog({
    required this.money,
    required this.planCooldownRemaining,
    required this.defaultDuration,
    required this.products,
  });

  final double money;
  final int planCooldownRemaining;
  final int defaultDuration;
  final List<ShopProduct> products;

  List<ShopProduct> ofType(String type) => <ShopProduct>[
    for (final ShopProduct product in products)
      if (product.type == type) product,
  ];

  factory ShopCatalog.fromJson(Map<String, dynamic> json) {
    final Object? products = json['products'];

    return ShopCatalog(
      money: (json['money'] as num?)?.toDouble() ?? 0,
      planCooldownRemaining:
          (json['plan_cooldown_remaining'] as num?)?.toInt() ?? 0,
      defaultDuration: (json['default_duration'] as num?)?.toInt() ?? 0,
      products: <ShopProduct>[
        if (products is List)
          for (final Object? item in products)
            if (item is Map<String, dynamic>) ShopProduct.fromJson(item),
      ],
    );
  }
}

/// 套餐下单预算，字段与网页 `getOrderStatus` 一一对应
class PlanQuote {
  const PlanQuote({
    required this.cooldown,
    required this.cooldownMsg,
    required this.cooldownRemaining,
    required this.name,
    required this.total,
    required this.basePrice,
    required this.hasLimitedSale,
    required this.hasStockLimit,
    required this.stock,
    required this.hasValidOrder,
    required this.upgradeMsg,
    required this.couponApplied,
    required this.couponMsg,
    required this.credit,
    required this.hasTrafficResetFee,
    required this.trafficResetFee,
    required this.trafficCurrentShopName,
    required this.trafficBillingBasePrice,
    required this.trafficUsed,
    required this.trafficTotal,
    required this.trafficUsagePercent,
    required this.trafficFeePercent,
    required this.trafficFeeIsCapped,
  });

  final bool cooldown;
  final String cooldownMsg;
  final int cooldownRemaining;
  final String name;
  final String total;
  final String basePrice;
  final bool hasLimitedSale;
  final bool hasStockLimit;
  final String stock;
  final bool hasValidOrder;
  final String upgradeMsg;
  final bool couponApplied;
  final String couponMsg;
  final int credit;
  final bool hasTrafficResetFee;
  final String trafficResetFee;
  final String trafficCurrentShopName;
  final String trafficBillingBasePrice;
  final double trafficUsed;
  final double trafficTotal;
  final double trafficUsagePercent;
  final double trafficFeePercent;
  final bool trafficFeeIsCapped;

  double get amount => parseAmount(total);

  factory PlanQuote.fromJson(Map<String, dynamic> json) => PlanQuote(
    cooldown: json['plan_cooldown'] as bool? ?? false,
    cooldownMsg: json['plan_cooldown_msg'] as String? ?? '',
    cooldownRemaining: (json['plan_cooldown_remaining'] as num?)?.toInt() ?? 0,
    name: json['name'] as String? ?? '',
    total: json['total'] as String? ?? '0.00',
    basePrice: json['base_price'] as String? ?? '',
    hasLimitedSale: json['has_limited_sale'] as bool? ?? false,
    hasStockLimit: json['has_stock_limit'] as bool? ?? false,
    stock: json['stock'] as String? ?? '',
    hasValidOrder: ((json['hasValidOrder'] as num?)?.toInt() ?? 0) == 1,
    upgradeMsg: json['upgradeMsg'] as String? ?? '',
    couponApplied: json['couponApplied'] as bool? ?? false,
    couponMsg: json['couponMsg'] as String? ?? '',
    credit: (json['credit'] as num?)?.toInt() ?? 0,
    hasTrafficResetFee: json['has_traffic_reset_fee'] as bool? ?? false,
    trafficResetFee: json['traffic_reset_fee'] as String? ?? '0.00',
    trafficCurrentShopName: json['traffic_current_shop_name'] as String? ?? '',
    trafficBillingBasePrice:
        json['traffic_billing_base_price'] as String? ?? '0.00',
    trafficUsed: (json['traffic_used'] as num?)?.toDouble() ?? 0,
    trafficTotal: (json['traffic_total'] as num?)?.toDouble() ?? 0,
    trafficUsagePercent:
        (json['traffic_usage_percent'] as num?)?.toDouble() ?? 0,
    trafficFeePercent: (json['traffic_fee_percent'] as num?)?.toDouble() ?? 0,
    trafficFeeIsCapped: json['traffic_fee_is_capped'] as bool? ?? false,
  );
}

/// 流量包 / 卡密下单前的商品状态
class ProductQuote {
  const ProductQuote({
    required this.name,
    required this.total,
    required this.stock,
    required this.hasStockLimit,
    required this.basePrice,
    required this.hasLimitedSale,
  });

  final String name;
  final String total;
  final String stock;
  final bool hasStockLimit;
  final String basePrice;
  final bool hasLimitedSale;

  double get amount => parseAmount(total);

  factory ProductQuote.fromJson(Map<String, dynamic> json) => ProductQuote(
    name: json['name'] as String? ?? '',
    total: json['total'] as String? ?? '0.00',
    stock: json['stock'] as String? ?? '',
    hasStockLimit: json['has_stock_limit'] as bool? ?? false,
    basePrice: json['base_price'] as String? ?? '',
    hasLimitedSale: json['has_limited_sale'] as bool? ?? false,
  );
}

class ShopPurchaseResult {
  const ShopPurchaseResult({
    required this.message,
    required this.cardKey,
    required this.tradeNo,
    required this.paymentUrl,
  });

  final String message;
  final String cardKey;
  final String tradeNo;
  final String paymentUrl;

  bool get needsOnlinePayment => paymentUrl.isNotEmpty;

  factory ShopPurchaseResult.fromEnvelope(Map<String, dynamic> envelope) {
    final Object? data = envelope['data'];
    final Map<String, dynamic> body = data is Map<String, dynamic>
        ? data
        : <String, dynamic>{};

    return ShopPurchaseResult(
      message: envelope['msg'] as String? ?? '',
      cardKey: body['card_key'] as String? ?? '',
      tradeNo: body['tradeno']?.toString() ?? '',
      paymentUrl: body['payment_url'] as String? ?? '',
    );
  }
}

class PaymentStatus {
  const PaymentStatus({
    required this.paid,
    required this.total,
    required this.cardKey,
  });

  final bool paid;
  final double total;
  final String cardKey;

  factory PaymentStatus.fromJson(Map<String, dynamic> json) => PaymentStatus(
    paid: json['paid'] as bool? ?? false,
    total: (json['total'] as num?)?.toDouble() ?? 0,
    cardKey: json['card_key'] as String? ?? '',
  );
}
