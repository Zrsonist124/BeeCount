package com.tntlikely.beecount

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.widget.Toast
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * 支付宝 / 微信支付通知队列。
 *
 * 通知监听服务抓到的支付通知先落盘到 SharedPreferences，Dart 侧启动或回前台
 * 时通过 `peekQueue` 拉取、逐条 `ackEvent`。这样即使 app 进程被杀，支付也不会
 * 丢；记账时间仍取通知的 postTime。
 */
object PaymentNotifyStore {
    private const val PREFS = "payment_notify_prefs"
    private const val KEY_QUEUE = "queue"
    private const val KEY_SEEN = "seen_keys"
    private const val MAX_QUEUE = 200
    private const val MAX_SEEN = 300

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun readQueue(context: Context): JSONArray {
        val raw = prefs(context).getString(KEY_QUEUE, "[]") ?: "[]"
        return try {
            JSONArray(raw)
        } catch (e: Exception) {
            JSONArray()
        }
    }

    private fun writeQueue(context: Context, queue: JSONArray) {
        prefs(context).edit().putString(KEY_QUEUE, queue.toString()).apply()
    }

    private fun seenKeys(context: Context): MutableList<String> {
        val raw = prefs(context).getString(KEY_SEEN, "[]") ?: "[]"
        val list = mutableListOf<String>()
        try {
            val arr = JSONArray(raw)
            for (i in 0 until arr.length()) list.add(arr.optString(i))
        } catch (_: Exception) {
        }
        return list
    }

    /** 入队；重复通知（同一 key）返回 false。 */
    @Synchronized
    fun append(context: Context, event: JSONObject): Boolean {
        val key = event.optString("key")
        val seen = seenKeys(context)
        if (key.isNotEmpty() && seen.contains(key)) return false

        val queue = readQueue(context)
        queue.put(event)
        while (queue.length() > MAX_QUEUE) {
            queue.remove(0)
        }
        writeQueue(context, queue)

        if (key.isNotEmpty()) {
            seen.add(key)
            while (seen.size > MAX_SEEN) seen.removeAt(0)
            prefs(context).edit().putString(KEY_SEEN, JSONArray(seen).toString()).apply()
        }
        return true
    }

    @Synchronized
    fun peek(context: Context): List<Map<String, Any?>> {
        val queue = readQueue(context)
        val result = mutableListOf<Map<String, Any?>>()
        for (i in 0 until queue.length()) {
            val item = queue.optJSONObject(i) ?: continue
            result.add(eventToMap(item))
        }
        return result
    }

    @Synchronized
    fun ack(context: Context, id: String) {
        val queue = readQueue(context)
        val kept = JSONArray()
        for (i in 0 until queue.length()) {
            val item = queue.optJSONObject(i) ?: continue
            if (item.optString("id") != id) kept.put(item)
        }
        writeQueue(context, kept)
    }

    /** Dart 侧撤销：连同通知一起清掉。 */
    @Synchronized
    fun removeById(context: Context, id: String): Boolean {
        val queue = readQueue(context)
        var removed = false
        val kept = JSONArray()
        for (i in 0 until queue.length()) {
            val item = queue.optJSONObject(i) ?: continue
            if (item.optString("id") == id) {
                removed = true
            } else {
                kept.put(item)
            }
        }
        if (removed) writeQueue(context, kept)
        return removed
    }

    @Synchronized
    fun count(context: Context): Int = readQueue(context).length()

    @Synchronized
    fun clear(context: Context) = writeQueue(context, JSONArray())

    fun eventToMap(o: JSONObject): Map<String, Any?> = mapOf(
        "id" to o.optString("id"),
        "source" to o.optString("source"),
        "pkg" to o.optString("pkg"),
        "title" to o.optString("title"),
        "text" to o.optString("text"),
        "postedAt" to o.optLong("postedAt")
    )
}

/** 系统设置里是否已授予「通知使用权」。 */
fun isNotificationAccessGranted(context: Context): Boolean {
    return try {
        val enabled = Settings.Secure.getString(
            context.contentResolver,
            "enabled_notification_listeners"
        ) ?: return false
        val component = ComponentName(context, PaymentNotificationListener::class.java)
        enabled.contains(component.flattenToString()) ||
            enabled.contains(context.packageName)
    } catch (e: Exception) {
        false
    }
}

/**
 * 支付宝 / 微信支付通知监听。
 *
 * 只在通知文本同时具备「金额」和「收支关键词」时入队，尽量不误记营销通知；
 * 真正的金额/方向/商户解析在 Dart 侧（PaymentNotificationParser）完成，
 * 便于单测和规则迭代。
 */
class PaymentNotificationListener : NotificationListenerService() {

    companion object {
        private const val TAG = "PaymentNotify"
        const val CHANNEL_ID = "payment_auto_billing"
        private const val CHANNEL_NAME = "支付自动记账"
        private const val PKG_WECHAT = "com.tencent.mm"
        private const val PKG_ALIPAY = "com.eg.android.AlipayGphone"
        private const val NOTIFY_ID_BASE = 7400

        private val KEYWORDS = listOf(
            "支付", "付款", "消费", "收款", "到账", "退款", "转账", "扣款", "入账"
        )
        private val MONEY_REGEX = Regex("[¥￥]\\s*\\d|\\d+(\\.\\d{1,2})?\\s*元")

        /** app 在前台时，Dart 侧会把这个 channel 挂上，用于实时记账。 */
        @Volatile
        var methodChannel: MethodChannel? = null

        @Volatile
        var isConnected: Boolean = false

        fun notifyIdFor(eventId: String): Int =
            NOTIFY_ID_BASE + (eventId.hashCode() and 0xFFFF)
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        isConnected = true
        LoggerPlugin.info(TAG, "通知监听服务已连接")
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        isConnected = false
        LoggerPlugin.warning(TAG, "通知监听服务断开，尝试重连")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                requestRebind(ComponentName(this, PaymentNotificationListener::class.java))
            } catch (_: Exception) {
            }
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        val notification = sbn ?: return
        val pkg = notification.packageName ?: return
        val source = when (pkg) {
            PKG_WECHAT -> "wechat"
            PKG_ALIPAY -> "alipay"
            else -> return
        }
        val n = notification.notification ?: return
        val extras = n.extras ?: return

        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty()
        val bigText = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString().orEmpty()
        val subText = extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString().orEmpty()
        val lines = extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
            ?.joinToString(" ") { it.toString() }.orEmpty()
        val summary = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            extras.getCharSequence(Notification.EXTRA_SUMMARY_TEXT)?.toString().orEmpty()
        } else {
            ""
        }

        val body = listOf(bigText, text, lines, summary, subText)
            .filter { it.isNotBlank() }
            .distinct()
            .joinToString(" ")
            .trim()
        if (body.isEmpty()) return

        val all = "$title $body"
        if (KEYWORDS.none { all.contains(it) }) return
        if (!MONEY_REGEX.containsMatchIn(all)) return

        val postedAt = if (notification.postTime > 0) notification.postTime
        else System.currentTimeMillis()
        // 同一条通知 1 分钟内不重复入队；通知更新（文字变化）仍可再次入队，
        // 由 Dart 侧按「渠道+金额+分钟」二次去重。
        val key = "$source|${body.hashCode()}|${postedAt / 60000}"
        val event = JSONObject().apply {
            put("id", UUID.randomUUID().toString())
            put("source", source)
            put("pkg", pkg)
            put("title", title)
            put("text", body)
            put("postedAt", postedAt)
            put("key", key)
        }

        if (!PaymentNotifyStore.append(this, event)) return
        LoggerPlugin.info(TAG, "捕获 $source 通知: $body")

        // app 在前台/引擎存活 → 立即交给 Dart 记账，此时不再额外弹提示（避免打扰）
        var delivered = false
        val channel = methodChannel
        if (channel != null) {
            try {
                channel.invokeMethod("onPaymentEvent", PaymentNotifyStore.eventToMap(event))
                delivered = true
            } catch (e: Exception) {
                LoggerPlugin.warning(TAG, "实时回调失败（改为下次启动补记）: ${e.message}")
            }
        }
        // 进程被杀 / 引擎不在时，给一条低优先级提示：告诉用户已捕获、可撤销
        if (!delivered) {
            postCapturedNotification(event, postedAt)
        }
    }

    /** 投一条低优先级提示：告诉用户「已捕获，待入账」，并给一个撤销按钮。 */
    private fun postCapturedNotification(event: JSONObject, postedAt: Long) {
        try {
            val manager =
                getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            ensureChannel(manager)

            val launch = packageManager.getLaunchIntentForPackage(packageName) ?: return
            launch.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            val eventId = event.optString("id")
            val requestCode = eventId.hashCode() and 0xFFFF
            val contentIntent = PendingIntent.getActivity(
                this, requestCode, launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val undoIntent = Intent(this, PaymentNotificationActionReceiver::class.java).apply {
                action = PaymentNotificationActionReceiver.ACTION_UNDO
                putExtra(PaymentNotificationActionReceiver.EXTRA_EVENT_ID, eventId)
            }
            val undoPending = PendingIntent.getBroadcast(
                this, requestCode + 1, undoIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val sourceLabel = if (event.optString("source") == "wechat") "微信" else "支付宝"
            val amount = extractAmountLabel(event.optString("text"))
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, CHANNEL_ID)
            } else {
                Notification.Builder(this)
            }
            builder
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle("已捕获一笔${sourceLabel}支付${if (amount.isNotEmpty()) " ¥$amount" else ""}")
                .setContentText("打开蜜蜂记账完成入账，或直接撤销")
                .setWhen(postedAt)
                .setAutoCancel(true)
                .setContentIntent(contentIntent)
                .setPriority(Notification.PRIORITY_LOW)
                .addAction(0, "撤销", undoPending)
            manager.notify(notifyIdFor(eventId), builder.build())
        } catch (e: Exception) {
            LoggerPlugin.warning(TAG, "提示通知发送失败: ${e.message}")
        }
    }

    private fun extractAmountLabel(text: String): String {
        val match = Regex("[¥￥]\\s*(\\d+(?:\\.\\d{1,2})?)|(\\d+(?:\\.\\d{1,2})?)\\s*元")
            .find(text) ?: return ""
        return match.groupValues.getOrNull(1)?.takeIf { it.isNotEmpty() }
            ?: match.groupValues.getOrNull(2).orEmpty()
    }

    private fun ensureChannel(manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "微信/支付宝支付通知自动记一笔的提示"
            setShowBadge(false)
            enableVibration(false)
            enableLights(false)
        }
        manager.createNotificationChannel(channel)
    }
}

/** 通知上的「撤销」按钮：把队列里这条删掉；若已被 Dart 记账则通知它删除。 */
class PaymentNotificationActionReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_UNDO = "com.tntlikely.beecount.PAYMENT_NOTIFY_UNDO"
        const val EXTRA_EVENT_ID = "event_id"
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        val ctx = context ?: return
        if (intent?.action != ACTION_UNDO) return
        val eventId = intent.getStringExtra(EXTRA_EVENT_ID) ?: return

        val removed = PaymentNotifyStore.removeById(ctx, eventId)
        try {
            val manager =
                ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.cancel(PaymentNotificationListener.notifyIdFor(eventId))
        } catch (_: Exception) {
        }

        // 已经落库的记录交给 Dart 删除（回前台或实时回调时处理）
        PaymentNotificationListener.methodChannel?.let { channel ->
            try {
                channel.invokeMethod("onUndoRequested", eventId)
            } catch (_: Exception) {
            }
        }

        Toast.makeText(
            ctx,
            if (removed) "已撤销这笔待入账记录" else "已撤销",
            Toast.LENGTH_SHORT
        ).show()
        LoggerPlugin.info("PaymentNotify", "用户撤销通知事件 $eventId")
    }
}
