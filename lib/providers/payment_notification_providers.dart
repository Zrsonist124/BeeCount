import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/automation/payment_notification_service.dart';

/// 通知自动记账服务（单例，内部持有 ProviderContainer）。
final paymentNotificationServiceProvider = Provider<PaymentNotificationService>(
    (ref) => PaymentNotificationService(ref.container));
