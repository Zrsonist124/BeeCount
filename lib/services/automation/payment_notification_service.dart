import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../ai/core/bill_info.dart';
import '../../providers.dart';
import '../../utils/app_localizations_resolver.dart';
import '../billing/bill_creation_service.dart';
import '../billing/post_processor.dart';
import '../data/tag_seed_service.dart';
import '../system/logger_service.dart';
import 'payment_notification_parser.dart';

/// 通知自动记账的最近一条记录（设置页展示 + 撤销用）。
class AutoRecordedPayment {
  const AutoRecordedPayment({
    required this.transactionId,
    required this.eventId,
    required this.source,
    required this.amount,
    required this.isExpense,
    required this.occurredAt,
    this.note,
  });

  final int transactionId;
  final String eventId;
  final PaymentSource source;
  final double amount;
  final bool isExpense;
  final DateTime occurredAt;
  final String? note;

  double get signedAmount => isExpense ? -amount : amount;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'txId': transactionId,
        'eventId': eventId,
        'source': source.key,
        'amount': amount,
        'isExpense': isExpense,
        'at': occurredAt.millisecondsSinceEpoch,
        'note': note,
      };

  static AutoRecordedPayment? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final source = PaymentSource.fromKey(raw['source']?.toString());
    final txId = raw['txId'];
    if (source == null || txId is! int) return null;
    return AutoRecordedPayment(
      transactionId: txId,
      eventId: (raw['eventId'] ?? '').toString(),
      source: source,
      amount: (raw['amount'] as num?)?.toDouble() ?? 0,
      isExpense: raw['isExpense'] != false,
      occurredAt: DateTime.fromMillisecondsSinceEpoch(
          (raw['at'] as num?)?.toInt() ?? 0),
      note: raw['note']?.toString(),
    );
  }
}

/// 支付宝 / 微信支付通知 → 自动记账。
///
/// 链路：Android [PaymentNotificationListener] 抓通知 → 入队（SharedPreferences）
/// → Dart 侧解析（[PaymentNotificationParser]）→ [BillCreationService] 落库。
/// app 在前台时走 MethodChannel 实时回调，在后台/被杀时下次启动补记，
/// 记账时间仍为通知发生时间。
class PaymentNotificationService with WidgetsBindingObserver {
  static const MethodChannel _channel =
      MethodChannel('com.tntlikely.beecount/payment_notification');

  static const String enabledKey = 'payment_notify_enabled';
  static const String _seenKey = 'payment_notify_seen';
  static const String _recentKey = 'payment_notify_recent';
  static const int _maxSeen = 400;
  static const int _maxRecent = 50;
  static const String _tag = 'PaymentNotify';

  final ProviderContainer _container;
  bool _draining = false;
  bool _initialized = false;

  static PaymentNotificationService? _instance;

  factory PaymentNotificationService(ProviderContainer container) {
    _instance ??= PaymentNotificationService._internal(container);
    return _instance!;
  }

  PaymentNotificationService._internal(this._container);

  /// 仅在 Android 上有实现（iOS 无法读取其他 app 的通知）。
  static bool get isSupported => Platform.isAndroid;

  /// 启动：挂 MethodChannel、监听生命周期、补记离线排队的支付。
  Future<void> init() async {
    if (_initialized) {
      await drainQueue();
      return;
    }
    _initialized = true;
    _channel.setMethodCallHandler(_onPlatformCall);
    WidgetsBinding.instance.addObserver(this);
    // 启动阶段原生 channel 还没注册（MainActivity 在 runApp 后才装配），
    // 这一次调用会拿到 MissingPluginException 并被吞掉；等第一帧后再补一次，
    // 保证「重启手机后第一次打开 app」也能把离线队列记进去。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      drainQueue();
    });
    await drainQueue();
  }

  Future<dynamic> _onPlatformCall(MethodCall call) async {
    switch (call.method) {
      case 'onPaymentEvent':
        final args = call.arguments;
        if (args is Map) {
          await _handleEvent(Map<dynamic, dynamic>.from(args));
        }
        return null;
      case 'onUndoRequested':
        await _handleNativeUndo((call.arguments ?? '').toString());
        return null;
      default:
        return null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 后台期间的通知可能在队列里，回到前台补记。
      drainQueue();
    }
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _channel.setMethodCallHandler(null);
  }

  // ---------------------------------------------------------------------------
  // 平台状态
  // ---------------------------------------------------------------------------

  /// 系统「通知使用权」是否已授予。
  Future<bool> isPermissionGranted() async {
    if (!isSupported) return false;
    try {
      final granted =
          await _channel.invokeMethod<bool>('isPermissionGranted') ?? false;
      return granted;
    } catch (e) {
      logger.warning(_tag, '查询通知权限失败: $e');
      return false;
    }
  }

  /// 原生监听服务是否已连接（授权后系统会拉起它）。
  Future<bool> isServiceConnected() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('isServiceConnected') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openSystemSettings() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('openPermissionSettings');
    } catch (e) {
      logger.warning(_tag, '打开通知使用权设置失败: $e');
    }
  }

  Future<int> queueCount() async {
    if (!isSupported) return 0;
    try {
      return await _channel.invokeMethod<int>('queueCount') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  // ---------------------------------------------------------------------------
  // 开关
  // ---------------------------------------------------------------------------

  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(enabledKey) ?? false;
  }

  Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(enabledKey, value);
    if (value) {
      await drainQueue();
    }
  }

  // ---------------------------------------------------------------------------
  // 队列消费
  // ---------------------------------------------------------------------------

  /// 拉取并处理离线排队的通知；每条处理成功后才 ack。
  Future<void> drainQueue() async {
    if (!isSupported || _draining) return;
    if (!await isEnabled()) return;
    _draining = true;
    var handled = 0;
    try {
      final items = await _channel.invokeListMethod<dynamic>('peekQueue') ??
          const <dynamic>[];
      for (final item in items) {
        if (item is! Map) continue;
        final map = Map<dynamic, dynamic>.from(item);
        // true = 已处理或确定不需要处理（可 ack）；false = 需要稍后重试。
        final settled = await _handleEvent(map);
        handled += settled ? 1 : 0;
        final id = (map['id'] ?? '').toString();
        if (settled && id.isNotEmpty) {
          await _channel.invokeMethod<void>('ackEvent', {'id': id});
        }
      }
      if (handled > 0) {
        logger.info(_tag, '通知队列处理完成', '出队 $handled 条（含重复/非支付）');
        _container.read(statsRefreshProvider.notifier).state++;
      }
    } catch (e, st) {
      logger.error(_tag, '消费通知队列失败', e, st);
    } finally {
      _draining = false;
    }
  }

  Future<void> _handleNativeUndo(String eventId) async {
    if (eventId.isEmpty) return;
    final record = await _findRecordByEvent(eventId);
    if (record != null) {
      await undo(record.transactionId);
    }
  }

  /// 解析 + 落库一条原生事件。
  ///
  /// 返回 true 表示「这条已经处理完，可以出队」（记账成功、重复、或确认不是
  /// 支付通知）；返回 false 表示「暂时处理不了」（开关关闭/无账本/落库异常），
  /// 事件必须留在队列里等下次重试，避免静默丢账。
  Future<bool> _handleEvent(Map<dynamic, dynamic> event) async {
    final parsed = PaymentNotificationParser.parse(event);
    if (parsed == null) {
      logger.debug(_tag, '通知不是可记账的支付，跳过',
          '${event['title']} | ${event['text']}');
      return true;
    }
    if (!await isEnabled()) return false;
    if (await _isDuplicate(parsed)) {
      logger.debug(_tag, '重复通知，跳过', parsed.toString());
      return true;
    }

    final ledgerId = await _resolveLedgerId();
    if (ledgerId == null) {
      logger.warning(_tag, '无可用账本，本次通知留在队列');
      return false;
    }

    try {
      final l10n = resolveAppLocalizations(null);
      final persister = BillCreationService(_container.read(repositoryProvider));
      final transactionId = await persister.createFromBill(
        bill: BillInfo(
          amount: parsed.signedAmount,
          time: parsed.occurredAt,
          note: parsed.note,
          type: parsed.isExpense ? BillType.expense : BillType.income,
          account: parsed.source.accountName,
          confidence: 0.9,
        ),
        ledgerId: ledgerId,
        billingTypes: const <String>[TagSeedService.billingTypeNotification],
        l10n: l10n,
      );
      if (transactionId == null) {
        logger.warning(_tag, '落库失败', parsed.toString());
        return false;
      }

      await _markSeen(parsed);
      await _pushRecent(AutoRecordedPayment(
        transactionId: transactionId,
        eventId: parsed.eventId,
        source: parsed.source,
        amount: parsed.amount,
        isExpense: parsed.isExpense,
        occurredAt: parsed.occurredAt,
        note: parsed.note,
      ));
      _container.read(statsRefreshProvider.notifier).state++;
      await PostProcessor.runC(_container, ledgerId: ledgerId, tags: true);
      logger.info(_tag, '通知自动记账成功',
          '${parsed.source.key} ${parsed.signedAmount} id=$transactionId');
      return true;
    } catch (e, st) {
      logger.error(_tag, '通知自动记账失败', e, st);
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // 去重 / 持久化
  // ---------------------------------------------------------------------------

  static String _dedupeKey(ParsedPayment payment) {
    final minute = payment.occurredAt.millisecondsSinceEpoch ~/ 60000;
    return '${payment.source.key}|'
        '${payment.amount.toStringAsFixed(2)}|$minute';
  }

  Future<bool> _isDuplicate(ParsedPayment payment) async {
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getStringList(_seenKey) ?? const <String>[];
    return seen.contains(payment.eventId) ||
        seen.contains(_dedupeKey(payment));
  }

  Future<void> _markSeen(ParsedPayment payment) async {
    final prefs = await SharedPreferences.getInstance();
    final seen = List<String>.from(
        prefs.getStringList(_seenKey) ?? const <String>[]);
    seen.add(payment.eventId);
    seen.add(_dedupeKey(payment));
    while (seen.length > _maxSeen) {
      seen.removeAt(0);
    }
    await prefs.setStringList(_seenKey, seen);
  }

  Future<void> _pushRecent(AutoRecordedPayment record) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_recentKey) ?? const <String>[];
    final updated = <String>[jsonEncode(record.toJson()), ...list];
    while (updated.length > _maxRecent) {
      updated.removeLast();
    }
    await prefs.setStringList(_recentKey, updated);
  }

  Future<List<AutoRecordedPayment>> recent() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_recentKey) ?? const <String>[];
    final result = <AutoRecordedPayment>[];
    for (final raw in list) {
      try {
        final decoded = AutoRecordedPayment.fromJson(jsonDecode(raw));
        if (decoded != null) result.add(decoded);
      } catch (_) {
        // 单条损坏不影响其它记录
      }
    }
    return result;
  }

  Future<AutoRecordedPayment?> _findRecordByEvent(String eventId) async {
    for (final record in await recent()) {
      if (record.eventId == eventId) return record;
    }
    return null;
  }

  /// 撤销一笔自动记账（真删，和手动删除行为一致）。
  Future<bool> undo(int transactionId) async {
    try {
      await _container.read(repositoryProvider).deleteTransaction(transactionId);
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_recentKey) ?? const <String>[];
      final kept = list
          .where((raw) {
            try {
              final decoded = AutoRecordedPayment.fromJson(jsonDecode(raw));
              return decoded?.transactionId != transactionId;
            } catch (_) {
              return true;
            }
          })
          .toList();
      await prefs.setStringList(_recentKey, kept);
      _container.read(statsRefreshProvider.notifier).state++;
      logger.info(_tag, '已撤销自动记账', 'txId=$transactionId');
      return true;
    } catch (e, st) {
      logger.error(_tag, '撤销自动记账失败', e, st);
      return false;
    }
  }

  Future<int?> _resolveLedgerId() async {
    try {
      return _container.read(currentLedgerIdProvider);
    } catch (_) {
      // provider 未就绪时回落到 prefs / 默认账本
    }
    final prefs = await SharedPreferences.getInstance();
    final fromPrefs = prefs.getInt('current_ledger_id');
    if (fromPrefs != null) return fromPrefs;
    try {
      final ledgers = await _container.read(repositoryProvider).getAllLedgers();
      if (ledgers.isEmpty) return null;
      return ledgers.first.id;
    } catch (_) {
      return null;
    }
  }
}
