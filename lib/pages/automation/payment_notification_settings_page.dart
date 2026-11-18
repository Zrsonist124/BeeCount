import 'package:beecount_ui/beecount_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/payment_notification_providers.dart';
import '../../services/automation/payment_notification_parser.dart';
import '../../services/automation/payment_notification_service.dart';

/// 支付宝 / 微信支付通知自动记账设置页。
///
/// 依赖 Android「通知使用权」：授权后 [PaymentNotificationListener] 抓取支付通知，
/// Dart 侧解析并落库，本页负责开关、授权入口、待处理队列与最近记录撤销。
class PaymentNotificationSettingsPage extends ConsumerStatefulWidget {
  const PaymentNotificationSettingsPage({super.key});

  @override
  ConsumerState<PaymentNotificationSettingsPage> createState() =>
      _PaymentNotificationSettingsPageState();
}

class _PaymentNotificationSettingsPageState
    extends ConsumerState<PaymentNotificationSettingsPage>
    with WidgetsBindingObserver {
  bool _loading = true;
  bool _enabled = false;
  bool _granted = false;
  bool _connected = false;
  bool _busy = false;
  int _queueCount = 0;
  List<AutoRecordedPayment> _recent = const <AutoRecordedPayment>[];

  PaymentNotificationService get _service =>
      ref.read(paymentNotificationServiceProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统设置授权完回来，自动刷新状态。
    if (state == AppLifecycleState.resumed) _reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _reload() async {
    if (!PaymentNotificationService.isSupported) {
      setState(() => _loading = false);
      return;
    }
    try {
      final enabled = await _service.isEnabled();
      final granted = await _service.isPermissionGranted();
      final connected = await _service.isServiceConnected();
      final queueCount = await _service.queueCount();
      final recent = await _service.recent();
      if (!mounted) return;
      setState(() {
        _enabled = enabled;
        _granted = granted;
        _connected = connected;
        _queueCount = queueCount;
        _recent = recent;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggle(bool value) async {
    if (_busy) return;
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await _service.setEnabled(value);
      if (value && !await _service.isPermissionGranted()) {
        await _service.openSystemSettings();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l.paymentNotifyGrantHint)),
          );
        }
      }
      await _reload();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _grant() async {
    await _service.openSystemSettings();
    await _reload();
  }

  Future<void> _processNow() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _service.drainQueue();
      await _reload();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _undo(AutoRecordedPayment record) async {
    final l = AppLocalizations.of(context);
    final ok = await _service.undo(record.transactionId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? l.paymentNotifyUndone : l.paymentNotifyUndoFailed),
      ),
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Column(
        children: [
          BeePageHeader(
            title: l.paymentNotifyTitle,
            leading: BeeIconButton(
              label: l.commonBack,
              icon: const BeeLineIcon('ChevronLeft', size: 22),
              onPressed: () => Navigator.maybePop(context),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    children: [
                      _infoCard(l, theme),
                      const SizedBox(height: 12),
                      if (!PaymentNotificationService.isSupported)
                        _unsupportedCard(l, theme)
                      else ...[
                        _switchCard(l, theme),
                        const SizedBox(height: 12),
                        _permissionCard(l, theme),
                        const SizedBox(height: 12),
                        _queueCard(l, theme),
                        const SizedBox(height: 12),
                        _recentCard(l, theme),
                      ],
                      const SizedBox(height: 12),
                      _privacyCard(l, theme),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 0),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      );

  Widget _infoCard(AppLocalizations l, ThemeData theme) => _card(context, [
        Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.paymentNotifyIntroTitle,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(l.paymentNotifyIntroBody,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.hintColor, height: 1.5)),
            ],
          ),
        ),
      ]);

  Widget _unsupportedCard(AppLocalizations l, ThemeData theme) => _card(context, [
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: Text(l.paymentNotifyUnsupported),
          subtitle: Text(l.paymentNotifyUnsupportedDesc),
        ),
      ]);

  Widget _switchCard(AppLocalizations l, ThemeData theme) => _card(context, [
        SwitchListTile(
          value: _enabled,
          onChanged: _busy ? null : _toggle,
          title: Text(l.paymentNotifyEnable),
          subtitle: Text(l.paymentNotifyEnableDesc),
        ),
      ]);

  Widget _permissionCard(AppLocalizations l, ThemeData theme) => _card(context, [
        ListTile(
          leading: Icon(
            _granted ? Icons.verified_user_outlined : Icons.warning_amber_rounded,
            color: _granted ? Colors.green : theme.colorScheme.error,
          ),
          title: Text(_granted
              ? l.paymentNotifyPermissionGranted
              : l.paymentNotifyPermissionMissing),
          subtitle: Text(_granted
              ? (_connected
                  ? l.paymentNotifyServiceConnected
                  : l.paymentNotifyServiceNotConnected)
              : l.paymentNotifyGrantHint),
          trailing: _granted
              ? null
              : TextButton(onPressed: _grant, child: Text(l.paymentNotifyGrant)),
        ),
      ]);

  Widget _queueCard(AppLocalizations l, ThemeData theme) => _card(context, [
        ListTile(
          leading: const Icon(Icons.inbox_outlined),
          title: Text(l.paymentNotifyQueueTitle(_queueCount)),
          subtitle: Text(l.paymentNotifyQueueDesc),
          trailing: TextButton(
            onPressed: _busy ? null : _processNow,
            child: Text(l.paymentNotifyProcessNow),
          ),
        ),
      ]);

  Widget _recentCard(AppLocalizations l, ThemeData theme) => _card(context, [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
          child: Text(l.paymentNotifyRecentTitle,
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ),
        if (_recent.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
            child: Text(l.paymentNotifyRecentEmpty,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.hintColor)),
          )
        else
          for (final record in _recent.take(20))
            ListTile(
              dense: true,
              leading: Icon(
                record.source == PaymentSource.wechat
                    ? Icons.chat_bubble_outline
                    : Icons.account_balance_wallet_outlined,
              ),
              title: Text(
                '${record.isExpense ? '-' : '+'}'
                '${record.amount.toStringAsFixed(2)} · ${record.source.accountName}',
                style: theme.textTheme.bodyMedium,
              ),
              subtitle: Text(
                '${DateFormat('MM-dd HH:mm').format(record.occurredAt)}'
                '${record.note == null || record.note!.isEmpty ? '' : ' · ${record.note}'}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.hintColor),
              ),
              trailing: TextButton(
                onPressed: () => _undo(record),
                child: Text(l.paymentNotifyUndo),
              ),
            ),
      ]);

  Widget _privacyCard(AppLocalizations l, ThemeData theme) => Text(
        l.paymentNotifyPrivacy,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.hintColor, height: 1.5),
      );
}
