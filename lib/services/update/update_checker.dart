import 'dart:async';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../system/logger_service.dart';
import 'update_result.dart';

/// 更新检查管理类
///
/// 策略：**优先读 releases 网页**，API 只作为补充。
/// 原因：GitHub 未登录 API 每小时只有 60 次，而移动网络普遍是运营商共享 IP，
/// 经常被别人吃光配额 → 返回 403，用户侧表现为「检查更新失败: DioException
/// [bad response]」。releases 网页没有这个限制，且不依赖 token。
class UpdateChecker {
  UpdateChecker._();

  /// 自建构建所在的仓库（见 .github/workflows/sync-upstream-build.yml）
  static const String _repoSlug = 'Zrsonist124/BeeCount';

  /// CI 里的 versionCode 规则：1000 + 运行序号
  static const int _buildCodeBase = 1000;

  static final Dio _dio = Dio();

  /// 清理 release notes，移除 commit hash 和链接
  static String _cleanReleaseNotes(String body) {
    if (body.isEmpty) return body;

    final lines = body.split('\n');
    final cleanedLines = <String>[];

    for (var line in lines) {
      // 跳过包含 "Full Changelog" 的行
      if (line.contains('Full Changelog')) continue;

      // 移除 commit hash 和链接部分：匹配 ([hash](url)) 格式
      final regex =
          RegExp(r'\s*\(\[[a-f0-9]{7}\]\(https://github\.com/[^\)]+\)\)');
      if (regex.hasMatch(line)) {
        line = line.replaceAll(regex, '');
      }

      if (line.trim().isEmpty) continue;
      cleanedLines.add(line);
    }

    return cleanedLines.join('\n').trim();
  }

  /// 生成随机User-Agent，避免被GitHub限制
  static String _generateRandomUserAgent() {
    final userAgents = [
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36',
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Safari/537.36',
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Safari/605.1.15',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/119.0',
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36',
    ];

    // 使用时间戳作为随机种子，确保每次调用都可能不同
    final random = (DateTime.now().millisecondsSinceEpoch % userAgents.length);
    return userAgents[random];
  }

  /// 检查更新信息
  static Future<UpdateResult> checkUpdate() async {
    try {
      final currentInfo = await _getAppInfo();
      final currentVersion = _normalizeVersion(currentInfo.version);
      final currentCode = int.tryParse(currentInfo.buildNumber) ?? 0;
      logger.info('UpdateChecker',
          '当前版本: $currentVersion (versionCode $currentCode)');

      _dio.options.connectTimeout = const Duration(seconds: 20);
      _dio.options.receiveTimeout = const Duration(minutes: 1);

      // 先走 API：能通就能拿到 release notes，拿不到再退回网页解析
      final viaApi = await _checkViaApi(currentInfo);
      if (viaApi != null) return viaApi;

      logger.warning('UpdateChecker', 'API 不可用，改用 releases 网页检测');
      return await _checkViaWeb(currentVersion, currentCode);
    } catch (e) {
      logger.error('UpdateChecker', '检查更新异常', e);
      return UpdateResult(
        hasUpdate: false,
        message: '__UPDATE_CHECK_EXCEPTION__:$e',
      );
    }
  }

  /// 走 GitHub API。返回 null 表示「这次 API 用不了」，交给网页方案兜底。
  static Future<UpdateResult?> _checkViaApi(AppInfo currentInfo) async {
    try {
      final resp = await _dio.get(
        'https://api.github.com/repos/$_repoSlug/releases/latest',
        options: Options(
          validateStatus: (_) => true, // 4xx 自己判断，不要抛异常
          headers: {
            'Accept': 'application/vnd.github+json',
            'User-Agent': _generateRandomUserAgent(),
          },
        ),
      );
      final status = resp.statusCode ?? 0;
      logger.info('UpdateChecker', 'API HTTP $status');
      if (status != 200 || resp.data is! Map) {
        logger.warning('UpdateChecker', 'API 不可用（HTTP $status），走网页兜底');
        return null;
      }

      final data = resp.data as Map;
      final tag = (data['tag_name'] ?? '').toString();
      final latestVersion = _normalizeVersion(tag);
      final assets = (data['assets'] as List?) ?? const [];
      final notes = _cleanReleaseNotes((data['body'] ?? '').toString());

      final buildMatch = RegExp(r'^build-(\d+)$').firstMatch(tag);
      if (buildMatch != null) {
        final candidate =
            _buildCodeBase + (int.tryParse(buildMatch.group(1)!) ?? 0);
        final current = int.tryParse(currentInfo.buildNumber) ?? 0;
        if (candidate <= current) {
          return UpdateResult(
            hasUpdate: false,
            message: '__UPDATE_ALREADY_LATEST_SIMPLE__',
          );
        }
        final apkUrl = _pickApkByAbi(assets);
        if (apkUrl == null) {
          return UpdateResult(
            hasUpdate: false,
            message: '__UPDATE_NO_APK_FOUND__',
          );
        }
        return UpdateResult(
          hasUpdate: true,
          version: _displayVersion((data['name'] ?? '').toString()),
          downloadUrl: apkUrl,
          releaseNotes: notes,
        );
      }

      // 语义化 tag（万一以后改成正式版本号发布）
      if (_isNewerVersion(latestVersion,
          _normalizeVersion(currentInfo.version))) {
        final apkUrl = _pickApkUrl(assets, latestVersion);
        if (apkUrl == null) {
          return UpdateResult(
            hasUpdate: false,
            message: '__UPDATE_NO_APK_FOUND__',
          );
        }
        return UpdateResult(
          hasUpdate: true,
          version: latestVersion,
          downloadUrl: apkUrl,
          releaseNotes: notes,
        );
      }
      return UpdateResult(
        hasUpdate: false,
        message: '__UPDATE_ALREADY_LATEST_SIMPLE__',
      );
    } catch (e) {
      logger.warning('UpdateChecker', 'API 请求异常，走网页兜底: $e');
      return null;
    }
  }

  /// 走 releases 网页（`/releases/latest` 会 302 到具体 tag 页面）。
  /// 不消耗 API 配额，移动网络下稳定得多。
  static Future<UpdateResult> _checkViaWeb(
      String currentVersion, int currentCode) async {
    final resp = await _dio.get(
      'https://github.com/$_repoSlug/releases/latest',
      options: Options(
        followRedirects: true,
        validateStatus: (s) => s != null && s < 500,
        headers: {'User-Agent': _generateRandomUserAgent()},
      ),
    );
    final status = resp.statusCode ?? 0;
    final finalUrl = resp.realUri.toString();
    logger.info('UpdateChecker', '网页 HTTP $status, 最终地址: $finalUrl');
    if (status != 200) {
      return UpdateResult(
        hasUpdate: false,
        message: '__UPDATE_CHECK_HTTP_FAILED__:$status',
      );
    }

    final html = resp.data.toString();
    final tag = RegExp(r'/releases/tag/([^/?#\s]+)').firstMatch(finalUrl)?.group(1) ??
        RegExp(r'/releases/tag/([^/?#"\s]+)').firstMatch(html)?.group(1) ??
        '';
    if (tag.isEmpty) {
      logger.warning('UpdateChecker', '网页里找不到 tag');
      return UpdateResult(hasUpdate: false, message: '__UPDATE_NO_APK_FOUND__');
    }
    logger.info('UpdateChecker', '网页最新 tag: $tag');

    final buildMatch = RegExp(r'^build-(\d+)$').firstMatch(tag);
    bool hasUpdate;
    String display;
    if (buildMatch != null) {
      final candidate =
          _buildCodeBase + (int.tryParse(buildMatch.group(1)!) ?? 0);
      hasUpdate = candidate > currentCode;
      // 版本号从页面标题里取（BeeCount 4.0.1 加固版 → 4.0.1），取不到就留空，
      // 绝不把 build-<序号> 暴露给用户
      display = RegExp(r'(\d+\.\d+\.\d+)').firstMatch(html)?.group(1) ?? '';
      logger.info('UpdateChecker',
          '网页比较: candidate=$candidate current=$currentCode');
    } else {
      hasUpdate = _isNewerVersion(_normalizeVersion(tag), currentVersion);
      display = _normalizeVersion(tag);
    }
    if (!hasUpdate) {
      return UpdateResult(
        hasUpdate: false,
        message: '__UPDATE_ALREADY_LATEST_SIMPLE__',
      );
    }

    // GitHub 的 release 页把资产列表做成懒加载片段，要单独请求
    // /releases/expanded_assets/<tag> 才能拿到 APK 文件名。
    var names = const <String>[];
    try {
      final frag = await _dio.get(
        'https://github.com/$_repoSlug/releases/expanded_assets/$tag',
        options: Options(
          validateStatus: (s) => s != null && s < 500,
          headers: {'User-Agent': _generateRandomUserAgent()},
        ),
      );
      if ((frag.statusCode ?? 0) == 200) {
        names = RegExp(r'/releases/download/[^/]+/([^"\s<>]+\.apk)')
            .allMatches(frag.data.toString())
            .map((m) => m.group(1)!)
            .toSet()
            .toList();
      } else {
        logger.warning('UpdateChecker', '资产片段 HTTP ${frag.statusCode}');
      }
    } catch (e) {
      logger.warning('UpdateChecker', '拉取资产列表失败: $e');
    }

    final name = _pickAssetName(names);
    if (name == null) {
      logger.warning('UpdateChecker', '没找到可用 APK 资产，候选: $names');
      return UpdateResult(hasUpdate: false, message: '__UPDATE_NO_APK_FOUND__');
    }

    return UpdateResult(
      hasUpdate: true,
      version: display,
      downloadUrl:
          'https://github.com/$_repoSlug/releases/download/$tag/$name',
      releaseNotes: '',
    );
  }

  /// 从 Release 标题里取语义化版本（`BeeCount 4.0.1 加固版` → `4.0.1`）
  static String _displayVersion(String releaseName) =>
      RegExp(r'(\d+\.\d+\.\d+)').firstMatch(releaseName)?.group(1) ?? '';

  /// 从 GitHub Release assets 列表里挑出适配当前设备的 APK（官方命名规则）。
  static String? _pickApkUrl(List assets, String version) {
    final apkByName = <String, String>{};
    for (final asset in assets) {
      final name = asset['name'].toString();
      if (name.endsWith('.apk')) {
        apkByName[name] = asset['browser_download_url'];
      }
    }
    if (apkByName.isEmpty) return null;

    final mainPkgName = 'beecount-$version.apk';
    final universalName = 'beecount-$version-universal.apk';
    if (apkByName.containsKey(mainPkgName)) return apkByName[mainPkgName];
    if (apkByName.containsKey(universalName)) return apkByName[universalName];
    return apkByName.values.first;
  }

  /// 自建 Release 的资产名是 `app-<abi>-prod-release.apk` / `app-prod-release.apk`，
  /// 按 ABI 优先级挑（arm64 真机优先，universal 兜底）。
  static String? _pickApkByAbi(List assets) {
    final names = <String>[];
    final urls = <String, String>{};
    for (final asset in assets) {
      final name = asset['name'].toString();
      if (name.endsWith('.apk')) {
        names.add(name);
        urls[name] = asset['browser_download_url'].toString();
      }
    }
    final chosen = _pickAssetName(names);
    return chosen == null ? null : urls[chosen];
  }

  /// 纯名字层面的 ABI 选择
  static String? _pickAssetName(List<String> names) {
    if (names.isEmpty) return null;
    for (final abi in const ['arm64-v8a', 'armeabi-v7a', 'x86_64']) {
      for (final name in names) {
        if (name.contains(abi)) return name;
      }
    }
    for (final name in names) {
      if (name.contains('universal')) return name;
    }
    return names.first;
  }

  // 辅助方法
  static Future<AppInfo> _getAppInfo() async {
    final p = await PackageInfo.fromPlatform();
    final commit = const String.fromEnvironment('GIT_COMMIT');
    final buildTime = const String.fromEnvironment('BUILD_TIME');
    final ciVersion = const String.fromEnvironment('CI_VERSION');

    final version = ciVersion.isNotEmpty ? ciVersion : 'dev-${p.version}';

    return AppInfo(version, p.buildNumber,
        commit: commit.isEmpty ? null : commit,
        buildTime: buildTime.isEmpty ? null : buildTime);
  }

  static String _normalizeVersion(String version) {
    String normalized = version;
    if (normalized.startsWith('v')) {
      normalized = normalized.substring(1);
    }
    if (normalized.startsWith('dev-')) {
      normalized = normalized.substring(4);
    }
    return normalized;
  }

  static bool _isNewerVersion(String newVersion, String currentVersion) =>
      (compareVersionNames(newVersion, currentVersion) ?? 0) > 0;

  /// SemVer precedence, with the existing v/dev- prefixes and short numeric
  /// legacy versions retained. Invalid names never become update candidates.
  @visibleForTesting
  static int? compareVersionNames(String candidate, String installed) {
    ({List<int> core, List<String> pre})? parse(String raw) {
      final match =
          RegExp(r'^(0|[1-9][0-9]*)(?:\.(0|[1-9][0-9]*))?(?:\.(0|[1-9][0-9]*))?'
                  r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
                  r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$')
              .firstMatch(_normalizeVersion(raw));
      if (match == null) return null;
      final core = [for (var i = 1; i <= 3; i++) int.tryParse(match[i] ?? '0')];
      if (core.contains(null)) return null;
      final pre = match[4]?.split('.') ?? <String>[];
      for (final id in pre) {
        if (RegExp(r'^[0-9]+$').hasMatch(id) &&
            id.length > 1 &&
            id.startsWith('0')) {
          return null;
        }
      }
      return (core: core.cast<int>(), pre: pre);
    }

    final left = parse(candidate), right = parse(installed);
    if (left == null || right == null) return null;
    for (var i = 0; i < 3; i++) {
      final order = left.core[i].compareTo(right.core[i]);
      if (order != 0) return order;
    }
    if (left.pre.isEmpty || right.pre.isEmpty) {
      return left.pre.isEmpty == right.pre.isEmpty
          ? 0
          : left.pre.isEmpty
              ? 1
              : -1;
    }
    for (var i = 0; i < left.pre.length && i < right.pre.length; i++) {
      final a = left.pre[i], b = right.pre[i];
      final aNumeric = RegExp(r'^[0-9]+$').hasMatch(a);
      final bNumeric = RegExp(r'^[0-9]+$').hasMatch(b);
      final order = aNumeric && bNumeric
          ? a.length == b.length
              ? a.compareTo(b)
              : a.length.compareTo(b.length)
          : aNumeric != bNumeric
              ? aNumeric
                  ? -1
                  : 1
              : a.compareTo(b);
      if (order != 0) return order;
    }
    return left.pre.length.compareTo(right.pre.length);
  }
}
