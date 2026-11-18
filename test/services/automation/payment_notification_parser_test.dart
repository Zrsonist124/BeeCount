import 'package:flutter_test/flutter_test.dart';

import 'package:beecount/services/automation/payment_notification_parser.dart';

/// 支付宝 / 微信支付通知解析规则单测。
///
/// 样本取自两类通知的常见文案（金额、收款、退款、营销、失败），用来锁住
/// 「宁可漏记不可错记」的边界：拿不准的一律返回 null。
void main() {
  Map<String, dynamic> event({
    String id = 'e1',
    String source = 'wechat',
    String title = '微信支付',
    required String text,
    int postedAt = 1700000000000,
  }) =>
      <String, dynamic>{
        'id': id,
        'source': source,
        'title': title,
        'text': text,
        'postedAt': postedAt,
      };

  group('微信支付', () {
    test('已支付¥12.00 解析为支出', () {
      final parsed =
          PaymentNotificationParser.parse(event(text: '已支付¥12.00'));
      expect(parsed, isNotNull);
      expect(parsed!.source, PaymentSource.wechat);
      expect(parsed.amount, 12.0);
      expect(parsed.isExpense, isTrue);
      expect(parsed.signedAmount, -12.0);
      expect(parsed.occurredAt.millisecondsSinceEpoch, 1700000000000);
    });

    test('收款到账解析为收入', () {
      final parsed = PaymentNotificationParser.parse(
          event(text: '微信支付收款 25.00 元'));
      expect(parsed, isNotNull);
      expect(parsed!.isExpense, isFalse);
      expect(parsed.amount, 25.0);
      expect(parsed.merchant, isNull, reason: '渠道名不算商户');
      expect(parsed.note, '微信');
    });

    test('带商户的文案能抽出商户', () {
      final parsed =
          PaymentNotificationParser.parse(event(text: '美团 支付成功 ¥20.00'));
      expect(parsed, isNotNull);
      expect(parsed!.merchant, '美团');
      expect(parsed.note, '美团');
    });

    test('退款到账算收入', () {
      final parsed =
          PaymentNotificationParser.parse(event(text: '退款到账 ¥15.00'));
      expect(parsed, isNotNull);
      expect(parsed!.isExpense, isFalse);
      expect(parsed.amount, 15.0);
    });

    test('失败通知不记账', () {
      expect(
          PaymentNotificationParser.parse(event(text: '支付失败 ¥12.00')),
          isNull);
    });

    test('还款提醒不记账', () {
      expect(
          PaymentNotificationParser.parse(
              event(text: '信用卡还款提醒：本期应还 1234.00 元')),
          isNull);
    });

    test('营销活动不记账', () {
      expect(
          PaymentNotificationParser.parse(
              event(text: '支付立减活动，最高优惠 20 元')),
          isNull);
    });

    test('没有金额不记账', () {
      expect(
          PaymentNotificationParser.parse(event(text: '你已成功支付，感谢使用')),
          isNull);
    });
  });

  group('支付宝', () {
    test('支付成功 12.00元 解析为支出', () {
      final parsed = PaymentNotificationParser.parse(event(
          source: 'alipay', title: '支付宝', text: '支付成功 12.00元'));
      expect(parsed, isNotNull);
      expect(parsed!.source, PaymentSource.alipay);
      expect(parsed.amount, 12.0);
      expect(parsed.isExpense, isTrue);
      expect(parsed.accountNameForTest, '支付宝');
    });

    test('千分位金额正确解析', () {
      final parsed = PaymentNotificationParser.parse(event(
          source: 'alipay', title: '支付宝', text: '你已成功付款 ¥1,299.00'));
      expect(parsed, isNotNull);
      expect(parsed!.amount, 1299.0);
    });

    test('余额宝收益不算支付', () {
      expect(
          PaymentNotificationParser.parse(event(
              source: 'alipay', title: '支付宝', text: '余额宝昨日收益 0.12 元')),
          isNull);
    });

    test('订单号不会被当成金额', () {
      final parsed = PaymentNotificationParser.parse(event(
          source: 'alipay',
          title: '支付宝',
          text: '支付成功 订单号 2026111800001234567890'));
      expect(parsed, isNull, reason: '没有货币符号/元单位的裸数字不算金额');
    });

    test('金额上限之外视为噪音', () {
      expect(
          PaymentNotificationParser.parse(event(
              source: 'alipay', title: '支付宝', text: '支付成功 99999999 元')),
          isNull);
    });
  });

  test('缺少 source / id 的事件直接丢弃', () {
    expect(PaymentNotificationParser.parse(event(text: '已支付¥1.00', id: '')),
        isNull);
    expect(
        PaymentNotificationParser.parse(
            event(text: '已支付¥1.00', source: 'unknown')),
        isNull);
  });
}

extension on ParsedPayment {
  String get accountNameForTest => source.accountName;
}
