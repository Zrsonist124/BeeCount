# 支付宝 / 微信支付通知自动记账（自定义功能）

> 本仓库 = [TNT-Likely/BeeCount](https://github.com/TNT-Likely/BeeCount) + 一个自定义功能：
> **手机收到微信支付 / 支付宝的付款、收款通知时，自动记一笔账。**
> 除该功能外，不改动原项目的任何行为。

## 1. 功能是什么

| 能力 | 说明 |
| --- | --- |
| 实时捕获 | Android 通知监听服务读取微信（`com.tencent.mm`）与支付宝（`com.eg.android.AlipayGphone`）的支付类通知 |
| 本地解析 | 金额、收支方向、商户、时间全部用本地正则 + 关键词规则解析，**不调用 AI、不联网、零费用** |
| 自动入账 | 解析成功即写入当前账本：账户记到「微信 / 支付宝」，并打上「通知记账」标签 |
| 可撤销 | 通知栏「撤销」按钮、设置页「最近自动记账」列表都能删掉这笔 |
| 离线补记 | app 被杀期间的通知先落盘排队，下次打开 app 时补记，记账时间仍是付款时间 |
| 去重 | 原生按 `渠道+文本+分钟`、Dart 按 `渠道+金额+分钟` 双重去重，通知重复推送不会记两笔 |

## 2. 开启方式

1. 设置 → 智能记账 → **支付通知自动记账**
2. 打开开关，按提示到系统设置里给「蜜蜂记账」授予**通知使用权**
   （Android 设置 → 通知 → 通知使用权 / 特殊应用权限）
3. 回到 app，状态显示「已获得通知使用权 / 监听服务运行中」即生效

> 权限说明：Android 的「通知使用权」只能读取通知文本，不能读取聊天内容、不能截屏、不能点击其他 app。
> 通知文本只在本机解析并落库，不上传任何服务器。

## 3. 覆盖范围与已知限制

- **仅 Android**：iOS 不允许第三方 app 读取其他 app 的通知，iOS 上改用「账单导入」或「分享截图记账」。
- **依赖通知存在**：微信/支付宝若关闭了「支付」通知，或在 app 内支付时不发通知，则捕获不到；可在微信「我 → 设置 → 消息通知」、支付宝「我的 → 设置 → 通用 → 新消息通知」里打开。
- **商户名常缺失**：微信支付通知通常只有金额，没有商户；解析不到商户时备注记「微信 / 支付宝」，分类可事后补。
- **不处理**：还款提醒、账单提醒、营销活动、支付失败/取消、验证码类通知（有黑名单拦截）。
- Google Play 构建（`GOOGLE_PLAY=true`）未做限制，但上架政策需自行评估通知权限用途说明。

## 4. 代码结构（改动清单）

| 文件 | 作用 |
| --- | --- |
| `android/app/src/main/kotlin/com/tntlikely/beecount/PaymentNotificationListener.kt` | 通知监听服务 + 落盘队列 `PaymentNotifyStore` + 撤销广播接收器 + 捕获提示通知 |
| `android/app/src/main/kotlin/com/tntlikely/beecount/MainActivity.kt` | 新增 MethodChannel `com.tntlikely.beecount/payment_notification` |
| `android/app/src/main/AndroidManifest.xml` | 注册 service / receiver（`BIND_NOTIFICATION_LISTENER_SERVICE`） |
| `lib/services/automation/payment_notification_parser.dart` | 纯 Dart 解析器（可单测） |
| `lib/services/automation/payment_notification_service.dart` | 队列消费、去重、落库、撤销、生命周期补记 |
| `lib/providers/payment_notification_providers.dart` | 服务 provider |
| `lib/pages/automation/payment_notification_settings_page.dart` | 设置页（开关 / 授权 / 队列 / 最近记录撤销） |
| `lib/pages/settings/smart_billing/bindings/smart_billing_entries.dart` | 设置入口（仅 Android 显示） |
| `lib/main.dart` | 启动时初始化并补记离线队列 |
| `lib/services/data/tag_seed_service.dart` | 新增记账方式标签 `notification` |
| `lib/l10n/app_zh.arb` / `app_en.arb` | 中英文案（繁中/韩文自动回退英文） |
| `test/services/automation/payment_notification_parser_test.dart` | 解析规则单测 |

## 5. 本地构建

```powershell
# 依赖：Flutter 3.27.3 (Dart 3.6.1)、JDK 17、Android SDK 36
flutter pub get
flutter gen-l10n
flutter analyze
flutter test test/services/automation/payment_notification_parser_test.dart
flutter build apk --flavor prod --release --build-name=4.0.0 --build-number=301
# 产物：build/app/outputs/flutter-apk/app-{armeabi-v7a,arm64-v8a,x86_64}-prod-release.apk
#       （另有 universal 的 app-prod-release.apk）
```

签名：`android/key.properties` 指向固定 keystore（`storeFile` 相对 `android/app/` 解析，
所以写 `../beecount-autobill.jks`）。**换签名会导致无法覆盖安装**（只能卸载重装，账本会丢）。
`--build-number` 必须递增，否则手机上无法覆盖安装。

## 6. 跟着上游自动更新

`.github/workflows/sync-upstream-build.yml`：

1. 每天北京时间 04:00 拉取上游 `TNT-Likely/BeeCount@main` 并 `git merge` 到当前分支；
2. 有变更 → 自动 `flutter analyze` + 单测 + 构建签名 APK → 发 GitHub Release；
3. **合并冲突会让工作流红灯**，不会静默丢掉本功能。冲突时要人工处理的地方基本只有：
   - `android/app/src/main/AndroidManifest.xml`
   - `MainActivity.kt` 里新增的 channel 段
   - `lib/main.dart` 的初始化调用
   - `lib/l10n/*.arb` 新增文案

启用步骤：

1. Fork 本仓库（或把自己的 fork 作为 upstream 的镜像），把本分支推到 `main`；
2. Settings → Actions → General → Workflow permissions 选 **Read and write**；
3. 配好固定签名 Secrets（否则每次构建签名不同，无法覆盖升级）：
   - `ANDROID_KEYSTORE_BASE64`：keystore 的 base64（`base64 -w0 release.jks`）
   - `ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`
4. 手动跑一次 `Sync upstream and build APK` 验证。

## 7. 隐私

- 通知文本只在本机内存 / 本地 SQLite 中处理；
- 解析规则离线运行，不请求 AI、不上传、不统计；
- 捕获提示通知走独立低优先级渠道（无声音、无角标），可在系统设置里单独关闭。
