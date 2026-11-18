/// 支付宝 / 微信支付通知解析器（纯 Dart，无平台依赖）。
///
/// 输入是 Android 通知监听服务（[PaymentNotificationListener]）上报的原始文本，
/// 输出结构化的一笔支付。**不做 AI 调用**：通知文本里的金额、方向、商户都用
/// 本地正则 + 关键词规则判断，保证离线、零成本、可单测。
///
/// 设计原则：
/// 1. 宁可漏记，不可错记 —— 命中不了规则就返回 null，交给用户在 app 里手动补；
/// 2. 只认「有钱 + 有收支关键词」的文本，账单提醒 / 营销 / 还款提示一律丢弃；
/// 3. 商户名可缺省（微信支付通知通常只有金额），缺省时用「微信支付/支付宝」兜底。
library;

/// 支付渠道。
enum PaymentSource {
  wechat,
  alipay;

  /// 落库时写入 account 字段的名称（走 [BillCreationService] 的账户模糊匹配）。
  String get accountName => this == PaymentSource.wechat ? '微信' : '支付宝';

  /// 渠道内部 key（与原生侧一致）。
  String get key => this == PaymentSource.wechat ? 'wechat' : 'alipay';

  static PaymentSource? fromKey(String? key) {
    switch (key) {
      case 'wechat':
        return PaymentSource.wechat;
      case 'alipay':
        return PaymentSource.alipay;
      default:
        return null;
    }
  }
}

/// 解析结果：一笔待落库的支付。
class ParsedPayment {
  const ParsedPayment({
    required this.eventId,
    required this.source,
    required this.amount,
    required this.isExpense,
    required this.occurredAt,
    required this.rawText,
    this.merchant,
    this.note,
  });

  /// 原生侧生成的事件 ID（用于撤销、去重）。
  final String eventId;

  final PaymentSource source;

  /// 金额，永远为正数；方向看 [isExpense]。
  final double amount;

  /// true = 支出，false = 收入（收款/退款）。
  final bool isExpense;

  final DateTime occurredAt;

  /// 原始通知文本（调试 / 备注兜底）。
  final String rawText;

  /// 商户名，可能为 null（微信支付通知通常不带商户）。
  final String? merchant;

  /// 落库用备注（≤15 字，符合账单备注习惯）。
  final String? note;

  double get signedAmount => isExpense ? -amount : amount;

  @override
  String toString() =>
      'ParsedPayment(${source.key}, $amount, expense=$isExpense, '
      'merchant=$merchant, at=$occurredAt)';
}

class PaymentNotificationParser {
  const PaymentNotificationParser._();

  /// 金额：优先「¥/￥ + 数字」，其次「数字 + 元」。
  static final RegExp _symbolAmount = RegExp(
    r'[¥￥]\s*(\d{1,3}(?:,\d{3})*(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)',
  );
  static final RegExp _yuanAmount = RegExp(
    r'(\d{1,3}(?:,\d{3})*(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)\s*元',
  );
  static final RegExp _plainAmount = RegExp(
    r'(?<![\d.])(\d{1,3}(?:,\d{3})*\.\d{2}|\d+\.\d{2})(?![\d])',
  );

  /// 出现这些词说明是「账单/营销/失败」类通知，直接放弃。
  static const List<String> _blockedWords = <String>[
    '还款',
    '账单已出',
    '账单日',
    '即将到期',
    '待还',
    '额度',
    '优惠',
    '立减',
    '活动',
    '邀请',
    '积分',
    '权益',
    '领取',
    '抽奖',
    '红包封面',
    '验证码',
    '登录',
    '失败',
    '未支付',
    '待支付',
    '超时',
    '已取消',
    '已关闭',
    '退款中',
    '申请退款',
    '撤销',
  ];

  /// 收入方向关键词（优先级高于支出）。
  static const List<String> _incomeWords = <String>[
    '收款',
    '到账',
    '收入',
    '退回',
    '退款',
    '返还',
    '入账',
    '转入',
    '收到',
  ];

  /// 支出方向关键词。
  static const List<String> _expenseWords = <String>[
    '支付',
    '付款',
    '消费',
    '扣款',
    '支出',
    '转出',
    '已付',
  ];

  /// 金额上限，超过视为解析噪音（如「额度 50000 元」）。
  static const double _maxAmount = 1000000;

  /// 解析一条原生上报事件；无法解析返回 null。
  ///
  /// [event] 结构：`{id, source, title, text, postedAt}`。
  static ParsedPayment? parse(Map<dynamic, dynamic> event) {
    final eventId = (event['id'] ?? '').toString();
    final source = PaymentSource.fromKey((event['source'] ?? '').toString());
    if (eventId.isEmpty || source == null) return null;

    final title = (event['title'] ?? '').toString();
    final body = (event['text'] ?? '').toString();
    final text = '$title $body'.trim();
    if (text.isEmpty) return null;

    // 红包封面/营销类文本里也带「元」，先挡掉。
    for (final word in _blockedWords) {
      if (text.contains(word)) return null;
    }

    final amount = extractAmount(text);
    if (amount == null) return null;

    // 方向只认正文：标题通常是渠道名（「支付宝」含「支付」二字），
    // 拿标题判断方向会把「余额宝收益」这类通知误判成支出。
    final directionText = body.isNotEmpty ? body : title;
    final isExpense = _isExpense(directionText);
    if (isExpense == null) return null;

    final postedAt = _parseTimestamp(event['postedAt']);
    final merchant = _extractMerchant(body.isNotEmpty ? body : title, amount);

    return ParsedPayment(
      eventId: eventId,
      source: source,
      amount: amount,
      isExpense: isExpense,
      occurredAt: postedAt,
      rawText: text,
      merchant: merchant,
      note: _buildNote(merchant, source),
    );
  }

  /// 从文本里抽金额；抽不到或明显不合理返回 null。
  ///
  /// 只辨认「带货币符号」或「带元」的金额 —— 裸数字太容易把「订单号 2026…」
  /// 当成金额。
  static double? extractAmount(String text) {
    String? raw;
    final symbolMatch = _symbolAmount.firstMatch(text);
    if (symbolMatch != null) {
      raw = symbolMatch.group(1);
    } else {
      final yuanMatch = _yuanAmount.firstMatch(text);
      if (yuanMatch != null) raw = yuanMatch.group(1);
    }
    // 兜底：发票/部分系统通知只给「12.00」两位小数，但要避免订单号。
    raw ??= _plainAmount.firstMatch(text)?.group(1);
    if (raw == null) return null;

    final value = double.tryParse(raw.replaceAll(',', ''));
    if (value == null || value <= 0 || value > _maxAmount) return null;
    return value;
  }

  /// 判断收支方向；无法判断返回 null。
  static bool? _isExpense(String text) {
    for (final word in _incomeWords) {
      if (text.contains(word)) return false;
    }
    for (final word in _expenseWords) {
      if (text.contains(word)) return true;
    }
    return null;
  }

  /// 尽量从正文里取商户名（「美团 支付成功」→ 美团）。
  static String? _extractMerchant(String text, double amount) {
    var cleaned = text;
    // 去掉金额本身，避免商户名里混进数字。
    cleaned = cleaned.replaceAll(_symbolAmount, ' ');
    cleaned = cleaned.replaceAll(_yuanAmount, ' ');
    cleaned = cleaned.replaceAll(RegExp(r'[¥￥]'), ' ');
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return null;

    final match = RegExp(r'^([^，,。.:：;；!！?？\s]{2,20}?)\s*(?:支付成功|付款成功|支付|付款|消费|收款|到账|退款)')
        .firstMatch(cleaned);
    final candidate = match?.group(1)?.trim();
    if (candidate == null || candidate.isEmpty) return null;

    // 纯渠道名/人称代词不算商户。
    const noise = <String>{
      '微信',
      '微信支付',
      '支付宝',
      '支付宝支付',
      '你',
      '您',
      '我',
      '支付',
      '付款',
      '消费',
      '收款',
      '到账',
      '退款',
      '交易',
      '订单',
    };
    if (noise.contains(candidate)) return null;
    if (RegExp(r'^\d').hasMatch(candidate)) return null;
    if (candidate.length > 15) return candidate.substring(0, 15);
    return candidate;
  }

  static String? _buildNote(String? merchant, PaymentSource source) {
    if (merchant != null && merchant.isNotEmpty) return merchant;
    return source.accountName;
  }

  static DateTime _parseTimestamp(Object? value) {
    if (value is int && value > 0) {
      return DateTime.fromMillisecondsSinceEpoch(value);
    }
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed != null && parsed > 0) {
        return DateTime.fromMillisecondsSinceEpoch(parsed);
      }
    }
    return DateTime.now();
  }
}
