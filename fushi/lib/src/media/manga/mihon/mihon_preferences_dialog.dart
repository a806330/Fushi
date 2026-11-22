import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/online/online_source_error_text.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// Mihon 在线来源的偏好编辑弹窗。
///
/// 文本偏好会保留为草稿，直到用户按下明确的“保存”按钮；开关、下拉和多选仍沿用
/// Mihon 的即时保存契约。此 widget 公开是为了用真实 manager/runtime 做交互回归测试。
class MihonPreferencesDialog extends StatefulWidget {
  const MihonPreferencesDialog({
    super.key,
    required this.manager,
    required this.source,
  });

  final MihonManager manager;
  final MangaOnlineSourceRow source;

  @override
  State<MihonPreferencesDialog> createState() => _MihonPreferencesDialogState();
}

class _MihonPreferencesDialogState extends State<MihonPreferencesDialog> {
  List<MihonPreference>? _preferences;
  Object? _error;
  String? _savingKey;
  bool _savingAll = false;
  final Map<String, String> _textDrafts = <String, String>{};

  /// 线路测速结果。只活在弹窗里：不写偏好、不替用户切换线路。
  final Map<String, _RouteProbe> _routeProbes = <String, _RouteProbe>{};
  final Set<String> _collapsedRoutes = <String>{};
  bool _probingRoutes = false;
  bool _disposed = false;
  bool _probeViaProxy = false;
  HttpClient? _probeClient;
  HttpClient? _directClient;

  static const Duration _routeProbeTimeout = Duration(seconds: 6);
  static const String _routeUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final List<MihonPreference> preferences = await widget.manager
          .getPreferences(widget.source);
      if (mounted) setState(() => _preferences = preferences);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MihonPreferencesDialog', error, stack);
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _save(MihonPreference original, Object? value) async {
    setState(() => _savingKey = original.key);
    try {
      final List<MihonPreference> preferences = await _persistPreference(
        original,
        value,
      );
      if (mounted) {
        setState(() {
          _preferences = preferences;
          if (_textDrafts[original.key] == value) {
            _textDrafts.remove(original.key);
          }
        });
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MihonPreferencesDialog', error, stack);
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _savingKey = null);
    }
  }

  Future<List<MihonPreference>> _persistPreference(
    MihonPreference original,
    Object? value,
  ) {
    final MihonPreference changed = MihonPreference(
      key: original.key,
      kind: original.kind,
      title: original.title,
      summary: original.summary,
      value: value,
      entries: original.entries,
      entryValues: original.entryValues,
    );
    return widget.manager.setPreference(widget.source, changed);
  }

  Future<void> _saveAllAndClose() async {
    final List<MihonPreference>? preferences = _preferences;
    if (preferences == null || _savingKey != null || _savingAll) return;
    setState(() => _savingAll = true);
    try {
      List<MihonPreference> updated = preferences;
      for (final MihonPreference preference in preferences) {
        if (preference.kind != MihonPreferenceKind.text) continue;
        final String? draft = _textDrafts[preference.key];
        if (draft == null || draft == (preference.value?.toString() ?? '')) {
          continue;
        }
        updated = await _persistPreference(preference, draft);
      }
      if (!mounted) return;
      setState(() {
        _preferences = updated;
        _textDrafts.clear();
      });
      Navigator.pop(context);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MihonPreferencesDialog', error, stack);
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _savingAll = false);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _probeClient?.close(force: true);
    _probeClient = null;
    _directClient?.close(force: true);
    _directClient = null;
    super.dispose();
  }

  String _routeProbeId(MihonPreference preference, int index) =>
      '${preference.key}#$index';

  bool _routeExpanded(String key) => !_collapsedRoutes.contains(key);

  /// 手动触发一次全线路测速。并发 4 条、单条 6 秒，结果只回填到弹窗。
  Future<void> _probeRoutes(MihonPreference preference) async {
    if (_probingRoutes) return;
    final int count = preference.entries.length;
    if (count == 0) return;
    setState(() {
      _probingRoutes = true;
      _collapsedRoutes.remove(preference.key);
      for (int index = 0; index < count; index++) {
        _routeProbes[_routeProbeId(preference, index)] = const _RouteProbe(
          _RouteProbeState.pending,
        );
      }
    });
    // 跟着本机系统代理走，才能和真实抓取同一条通道（Clash 规则再决定
    // 直连还是转发）。代理不通时由 _probeOne 回退直连重试。
    final String? proxy = await _SystemProxy.resolve();
    if (_disposed || !mounted) return;
    _probeClient?.close(force: true);
    _directClient?.close(force: true);
    final HttpClient client = HttpClient()
      ..connectionTimeout = _routeProbeTimeout
      ..findProxy = (Uri uri) => proxy == null ? 'DIRECT' : 'PROXY $proxy'
      ..userAgent = _routeUserAgent;
    _probeClient = client;
    _probeViaProxy = proxy != null;
    _directClient = proxy == null
        ? null
        : (HttpClient()
            ..connectionTimeout = _routeProbeTimeout
            ..findProxy = (Uri uri) => 'DIRECT'
            ..userAgent = _routeUserAgent);

    int cursor = 0;
    Future<void> lane() async {
      while (true) {
        final int index = cursor;
        cursor++;
        if (index >= count) return;
        final String? url = _routeUrlOf(preference, index);
        final _RouteProbe result = url == null
            ? const _RouteProbe(_RouteProbeState.failed, null, '无网址')
            : await _probeOne(client, url);
        if (_disposed || !mounted) return;
        setState(() {
          _routeProbes[_routeProbeId(preference, index)] = result;
        });
      }
    }

    final int lanes = count < 4 ? count : 4;
    await Future.wait(<Future<void>>[
      for (int laneIndex = 0; laneIndex < lanes; laneIndex++) lane(),
    ]);
    if (_disposed || !mounted) return;
    setState(() => _probingRoutes = false);
  }

  /// 单条线路的一次轻量请求：只读前 4KB，计时到首段正文到达。
  ///
  /// 判据是「有没有拿到 HTTP 响应」，不是状态码：不少镜像对根路径故意回
  /// 500/403 的反爬占位页，线路其实是通的。先走系统代理（与真实抓取同通
  /// 道），连接层失败再直连重试一次。
  Future<_RouteProbe> _probeOne(HttpClient client, String url) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      return const _RouteProbe(_RouteProbeState.failed, null, '网址无效');
    }
    final _RouteProbe? first = await _probeOnce(client, uri);
    if (first != null) return first;
    final HttpClient? direct = _directClient;
    if (!_probeViaProxy || direct == null) {
      return const _RouteProbe(_RouteProbeState.failed);
    }
    return await _probeOnce(direct, uri) ??
        const _RouteProbe(_RouteProbeState.failed);
  }

  /// 返回 null 表示连接层没通（可以换通道重试）；其余都带结论。
  Future<_RouteProbe?> _probeOnce(HttpClient client, Uri uri) async {
    final Stopwatch watch = Stopwatch()..start();
    try {
      final HttpClientRequest request = await client
          .getUrl(uri)
          .timeout(_routeProbeTimeout);
      request.followRedirects = true;
      request.maxRedirects = 5;
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-4095');
      final HttpClientResponse response = await request
          .close()
          .timeout(_routeProbeTimeout);
      final List<int> head = <int>[];
      try {
        await for (final List<int> chunk
            in response.timeout(_routeProbeTimeout)) {
          head.addAll(chunk);
          if (head.length >= 4096) break;
        }
      } on Object {
        // 正文只来了一半也算通，慢不慢由首包耗时反映。
      }
      watch.stop();
      final int milliseconds = watch.elapsedMilliseconds;
      final int status = response.statusCode;
      final String body = utf8
          .decode(head, allowMalformed: true)
          .toLowerCase();
      final bool challenge = body.contains('just a moment') ||
          body.contains('cf-browser-verification') ||
          body.contains('checking your browser');
      if (challenge) {
        return _RouteProbe(_RouteProbeState.blocked, milliseconds, '$status');
      }
      if (status >= 400) {
        return _RouteProbe(_RouteProbeState.reachable, milliseconds, '$status');
      }
      return _RouteProbe(_RouteProbeState.ok, milliseconds, null);
    } on TimeoutException {
      watch.stop();
      return const _RouteProbe(_RouteProbeState.timeout);
    } on Object {
      watch.stop();
      return null;
    }
  }

  // ---- 线路偏好识别 ---------------------------------------------------------

  /// 列表偏好里至少两条候选能解析出网址，才当成线路清单。
  ///
  /// 有的源 `entryValues` 直接是网址；有的源 `entryValues` 只是编号、网址写在
  /// `entries` 的显示名里——两种都认，不绑死任何源。
  bool _looksLikeRouteList(MihonPreference preference) {
    if (preference.kind != MihonPreferenceKind.list) return false;
    int resolved = 0;
    for (int index = 0; index < preference.entries.length; index++) {
      if (_routeUrlOf(preference, index) != null) {
        resolved++;
        if (resolved >= 2) return true;
      }
    }
    return false;
  }

  String _routeRawValue(MihonPreference preference, int index) {
    if (index < preference.entryValues.length) {
      final String value = preference.entryValues[index].trim();
      if (value.isNotEmpty) return value;
    }
    return index < preference.entries.length ? preference.entries[index] : '';
  }

  String _routeLabel(MihonPreference preference, int index) {
    final String label = index < preference.entries.length
        ? preference.entries[index].trim()
        : '';
    if (label.isNotEmpty) return label;
    return _routeRawValue(preference, index);
  }

  String? _routeUrlOf(MihonPreference preference, int index) =>
      _cleanRouteUrl(_routeRawValue(preference, index)) ??
      _cleanRouteUrl(_routeLabel(preference, index));

  static final RegExp _routeUrlPattern = RegExp(
    r'https?://[^\s"<>，,]+',
    caseSensitive: false,
  );
  static final RegExp _routeHostPattern = RegExp(
    r'(?:^|[\s(（,，:：])((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,})',
    caseSensitive: false,
  );

  String? _cleanRouteUrl(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) return null;
    final RegExpMatch? urlMatch = _routeUrlPattern.firstMatch(text);
    final RegExpMatch? hostMatch = urlMatch == null
        ? _routeHostPattern.firstMatch(text)
        : null;
    final String? found = (urlMatch?.group(0) ?? hostMatch?.group(1))?.trim();
    if (found == null || found.isEmpty) return null;
    final String lower = found.toLowerCase();
    final String cleaned = _trimRouteTail(
      lower.startsWith('http://') || lower.startsWith('https://')
          ? found
          : 'https://$found',
    );
    final Uri? uri = Uri.tryParse(cleaned);
    if (uri == null || uri.host.isEmpty || !uri.host.contains('.')) return null;
    if (RegExp(r'\s').hasMatch(uri.host)) return null;
    return cleaned;
  }

  String _trimRouteTail(String input) {
    const String tails = "，,;；)）]}\"'>。.";
    int end = input.length;
    while (end > 0 && tails.contains(input[end - 1])) {
      end--;
    }
    return input.substring(0, end);
  }

  // ---- 线路选择区渲染 -------------------------------------------------------

  Widget _buildRoutePicker(MihonPreference preference, bool busy) {
    final ThemeData theme = Theme.of(context);
    final int count = preference.entries.length;
    final int current = (preference.value as int? ?? 0).clamp(0, count - 1);
    final bool expanded = _routeExpanded(preference.key);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() {
              if (expanded) {
                _collapsedRoutes.add(preference.key);
              } else {
                _collapsedRoutes.remove(preference.key);
              }
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          preference.title,
                          style: theme.textTheme.bodyLarge,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '当前：${_routeLabel(preference, current)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  FushiTextButton(
                    onPressed: busy || _probingRoutes
                        ? null
                        : () => unawaited(_probeRoutes(preference)),
                    child: Text(_probingRoutes ? '测速中' : '测速'),
                  ),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            for (int index = 0; index < count; index++)
              _buildRouteRow(preference, index, index == current, busy),
        ],
      ),
    );
  }

  Widget _buildRouteRow(
    MihonPreference preference,
    int index,
    bool selected,
    bool busy,
  ) {
    final ThemeData theme = Theme.of(context);
    final _RouteProbe? probe = _routeProbes[_routeProbeId(preference, index)];
    final String? url = _routeUrlOf(preference, index);
    final String label = _routeLabel(preference, index);
    return InkWell(
      onTap: busy ? null : () => unawaited(_save(preference, index)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
        child: Row(
          children: <Widget>[
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (url != null && url != label)
                    Text(
                      url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _buildRouteSpeed(theme, probe),
          ],
        ),
      ),
    );
  }

  Widget _buildRouteSpeed(ThemeData theme, _RouteProbe? probe) {
    final TextStyle? base = theme.textTheme.bodySmall;
    if (probe == null) {
      return Text(
        '—',
        style: base?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    if (probe.state == _RouteProbeState.pending) {
      return const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 1.6),
      );
    }
    if (probe.state == _RouteProbeState.ok) {
      final int milliseconds = probe.milliseconds ?? 0;
      return Text(
        '$milliseconds ms',
        style: base?.copyWith(color: _routeSpeedColor(theme, milliseconds)),
      );
    }
    if (probe.state == _RouteProbeState.reachable) {
      final int milliseconds = probe.milliseconds ?? 0;
      final String? code = probe.note;
      return Text(
        code == null ? '$milliseconds ms' : '$milliseconds ms · $code',
        style: base?.copyWith(color: const Color(0xFFFB8C00)),
      );
    }
    if (probe.state == _RouteProbeState.blocked) {
      return Text(
        '拦截',
        style: base?.copyWith(color: theme.colorScheme.tertiary),
      );
    }
    if (probe.state == _RouteProbeState.timeout) {
      return Text(
        '超时',
        style: base?.copyWith(color: theme.colorScheme.error),
      );
    }
    return Text(
      probe.note ?? '失败',
      style: base?.copyWith(color: theme.colorScheme.error),
    );
  }

  Color _routeSpeedColor(ThemeData theme, int milliseconds) {
    if (milliseconds <= 1200) return const Color(0xFF43A047);
    if (milliseconds <= 3000) return const Color(0xFFFB8C00);
    return theme.colorScheme.error;
  }

  @override
  Widget build(BuildContext context) {
    final List<MihonPreference>? preferences = _preferences;
    return FushiAlertDialog(
      title: Text('${widget.source.name} · ${t.mihon_source_preferences}'),
      content: SizedBox(
        width: 480,
        // 2026-10 体验优化：不再把原始异常 toString 直接给用户看。
        child: _error != null
            ? Text(describeOnlineSourceError(_error!))
            : preferences == null
            ? Center(child: adaptiveIndicator(context: context))
            : preferences.isEmpty
            ? Text(t.mihon_source_no_results)
            : ListView(
                shrinkWrap: true,
                children: <Widget>[
                  for (final MihonPreference preference in preferences)
                    _buildPreference(preference),
                ],
              ),
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: _savingAll ? null : () => Navigator.pop(context),
          child: Text(t.dialog_close),
        ),
        FushiFilledButton(
          onPressed:
              preferences == null ||
                  _error != null ||
                  _savingKey != null ||
                  _savingAll
              ? null
              : () => unawaited(_saveAllAndClose()),
          child: Text(t.dialog_save),
        ),
      ],
    );
  }

  Widget _buildPreference(MihonPreference preference) {
    final bool busy = _savingAll || _savingKey == preference.key;
    return switch (preference.kind) {
      MihonPreferenceKind.checkBox ||
      MihonPreferenceKind.switchControl => FushiSwitchListTile.adaptive(
        title: Text(preference.title),
        subtitle: preference.summary.isEmpty ? null : Text(preference.summary),
        value: preference.value == true,
        onChanged: busy
            ? null
            : (bool value) => unawaited(_save(preference, value)),
      ),
      MihonPreferenceKind.text => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: FushiTextFormFieldControl(
          key: ValueKey<String>('${preference.key}:${preference.value}'),
          initialValue: preference.value?.toString() ?? '',
          enabled: !busy,
          decoration: InputDecoration(
            labelText: preference.title,
            helperText: preference.summary.isEmpty ? null : preference.summary,
          ),
          onChanged: (String value) => _textDrafts[preference.key] = value,
          onFieldSubmitted: (String value) =>
              unawaited(_save(preference, value)),
        ),
      ),
      MihonPreferenceKind.list => _looksLikeRouteList(preference)
          ? _buildRoutePicker(preference, busy)
          : FushiDropdownButtonFormField<int>(
              value: (preference.value as int? ?? 0).clamp(
                0,
                preference.entries.length - 1,
              ),
              decoration: InputDecoration(
                labelText: preference.title,
                helperText: preference.summary.isEmpty
                    ? null
                    : preference.summary,
              ),
              items: <DropdownMenuItem<int>>[
                for (int index = 0; index < preference.entries.length; index++)
                  DropdownMenuItem<int>(
                    value: index,
                    child: Text(preference.entries[index]),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (int? value) => unawaited(_save(preference, value ?? 0)),
            ),
      MihonPreferenceKind.multiSelect => FushiExpansionTile(
        title: Text(preference.title),
        subtitle: preference.summary.isEmpty ? null : Text(preference.summary),
        children: <Widget>[
          for (int index = 0; index < preference.entries.length; index++)
            _MihonMultiSelectRow(
              label: preference.entries[index],
              selected:
                  (preference.value as List<Object?>? ?? const <Object?>[])
                      .map((Object? value) => value.toString())
                      .contains(preference.entryValues[index]),
              onChanged: busy
                  ? null
                  : (bool? selected) {
                      final Set<String> values =
                          (preference.value as List<Object?>? ??
                                  const <Object?>[])
                              .map((Object? value) => value.toString())
                              .toSet();
                      if (selected == true) {
                        values.add(preference.entryValues[index]);
                      } else {
                        values.remove(preference.entryValues[index]);
                      }
                      unawaited(_save(preference, values.toList()));
                    },
            ),
        ],
      ),
      MihonPreferenceKind.unsupported => FushiListItem(
        leading: const FushiIcon(Icons.warning_amber_outlined),
        title: Text(preference.title),
        subtitle: Text(t.mihon_extension_incompatible),
      ),
    };
  }
}

/// 多选偏好的一行。
///
/// 框架的 `CheckboxListTile` 是被 MD3 守卫禁用的本地 chrome；共享的
/// [FushiListItem] 没有内建复选语义，所以这里把「点整行 = 切换」的行为显式接上，
/// 与 `CheckboxListTile` 的交互等价（整行可点，禁用态整行不可点）。
class _MihonMultiSelectRow extends StatelessWidget {
  const _MihonMultiSelectRow({
    required this.label,
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final ValueChanged<bool?>? changed = onChanged;
    return FushiListItem(
      title: Text(label),
      leading: FushiCheckbox(value: selected, onChanged: changed),
      onTap: changed == null ? null : () => changed(!selected),
    );
  }
}

/// 一条线路的测速结果：只用于弹窗展示。
enum _RouteProbeState { pending, ok, reachable, blocked, timeout, failed }

class _RouteProbe {
  const _RouteProbe(this.state, [this.milliseconds, this.note]);

  final _RouteProbeState state;
  final int? milliseconds;
  final String? note;
}

/// 读出本机系统代理，让测速与真实抓取走同一条通道。
///
/// Dart 自带的 `findProxyFromEnvironment` 只认环境变量，而 Windows 的系
/// 统代理写在注册表里（Clash Verge 等工具只改注册表），所以这里补一条注
/// 册表读取。不硬编码任何端口：读不到就当没有代理，测速退回直连。
class _SystemProxy {
  const _SystemProxy._();

  static String? _cached;
  static bool _resolved = false;

  static Future<String?> resolve() async {
    if (_resolved) return _cached;
    _resolved = true;
    _cached = _fromEnvironment() ?? await _fromWindowsRegistry();
    return _cached;
  }

  static String? _fromEnvironment() {
    for (final String key in const <String>[
      'https_proxy',
      'HTTPS_PROXY',
      'http_proxy',
      'HTTP_PROXY',
      'all_proxy',
      'ALL_PROXY',
    ]) {
      final String? value = Platform.environment[key];
      if (value != null && value.trim().isNotEmpty) {
        final String? parsed = _normalize(value);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  static Future<String?> _fromWindowsRegistry() async {
    if (!Platform.isWindows) return null;
    try {
      final ProcessResult result = await Process.run(
        'reg',
        <String>[
          'query',
          r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
        ],
        stdoutEncoding: null,
        stderrEncoding: null,
      );
      if (result.exitCode != 0) return null;
      final Object? raw = result.stdout;
      if (raw is! List<int>) return null;
      // reg 输出是本地代码页，中文会乱；这里只解析 ASCII 字段，按字节直转即可。
      final String text = String.fromCharCodes(raw);
      final RegExpMatch? enabled = RegExp(
        r'ProxyEnable\s+REG_DWORD\s+0x([0-9a-fA-F]+)',
      ).firstMatch(text);
      if (enabled == null) return null;
      if (int.parse(enabled.group(1)!, radix: 16) == 0) return null;
      final RegExpMatch? server = RegExp(
        r'ProxyServer\s+REG_SZ\s+(\S+)',
      ).firstMatch(text);
      if (server == null) return null;
      return _normalize(server.group(1)!);
    } on Object {
      return null;
    }
  }

  /// 收敛成 `host:port`。`http=a;https=b` 形式优先取 https。
  static String? _normalize(String raw) {
    String value = raw.trim();
    if (value.isEmpty) return null;
    if (value.contains('=')) {
      String? picked;
      for (final String part in value.split(';')) {
        final int eq = part.indexOf('=');
        if (eq <= 0) continue;
        final String scheme = part.substring(0, eq).trim().toLowerCase();
        final String target = part.substring(eq + 1).trim();
        if (target.isEmpty) continue;
        if (scheme == 'https') {
          picked = target;
          break;
        }
        picked ??= target;
      }
      if (picked == null) return null;
      value = picked;
    }
    value = value.replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://'), '');
    value = value.split('/').first.trim();
    if (!value.contains(':')) return null;
    return value;
  }
}
