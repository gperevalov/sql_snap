import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../github_sync.dart';
import '../lan_server.dart';
import '../store.dart';
import 'common.dart';

class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  final store = AppStore.instance;
  final lan = LanServer.instance;
  late final TextEditingController _repo, _branch, _dir, _token, _port;
  bool _busy = false;
  bool _tokenSaved = false;

  @override
  void initState() {
    super.initState();
    _repo = TextEditingController(text: store.github.repo);
    _branch = TextEditingController(text: store.github.branch);
    _dir = TextEditingController(text: store.github.dir);
    _token = TextEditingController();
    _port = TextEditingController(text: '${store.lanPort}');
    store.githubToken().then((t) {
      if (mounted) setState(() => _tokenSaved = t.isNotEmpty);
    });
  }

  @override
  void dispose() {
    for (final c in [_repo, _branch, _dir, _token, _port]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<GithubSync?> _gh() async {
    store.github
      ..repo = _repo.text.trim()
      ..branch = _branch.text.trim().isEmpty ? 'main' : _branch.text.trim()
      ..dir = _dir.text.trim();
    store.save();
    if (_token.text.trim().isNotEmpty) {
      await store.setGithubToken(_token.text.trim());
      _token.clear();
      setState(() => _tokenSaved = true);
    }
    final token = await store.githubToken();
    if (token.isEmpty) {
      if (mounted) toast(context, 'Укажите GitHub токен', error: true);
      return null;
    }
    return GithubSync(store, token);
  }

  Future<void> _busyRun(Future<String> Function() f) async {
    setState(() => _busy = true);
    try {
      final msg = await f();
      if (mounted) toast(context, msg);
    } catch (e) {
      if (mounted) toast(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pull() async {
    final gh = await _gh();
    if (gh == null) return;
    await _busyRun(gh.pull);
  }

  Future<void> _push() async {
    final gh = await _gh();
    if (gh == null || !mounted) return;
    var deleteMissing = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Отправить в GitHub'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Изменённые шаблоны будут закоммичены в репозиторий.'),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: deleteMissing,
              onChanged: (v) => setS(() => deleteMissing = v ?? false),
              title: const Text('Удалить из репо .sql, которых нет на телефоне'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Отправить')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _busyRun(() => gh.push(deleteMissing: deleteMissing));
  }

  Future<void> _export() async {
    final withPwd = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Экспорт в буфер обмена'),
        content: const Text('Включить пароли подключений? Не пересылайте такой файл через общие каналы.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('С паролями')),
          FilledButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Без паролей')),
        ],
      ),
    );
    if (withPwd == null) return;
    final b = await store.exportBundle(withPasswords: withPwd);
    if (!mounted) return;
    await copyText(context, const JsonEncoder.withIndent('  ').convert(b), 'JSON скопирован в буфер обмена');
  }

  Future<void> _importClipboard() async {
    final d = await Clipboard.getData('text/plain');
    final text = d?.text ?? '';
    await _importText(text);
  }

  Future<void> _importText(String text) async {
    try {
      final j = jsonDecode(text) as Map<String, dynamic>;
      final msg = await store.importBundle(j);
      if (mounted) toast(context, msg);
    } catch (e) {
      if (mounted) toast(context, 'Не похоже на экспорт SQL Snap: $e', error: true);
    }
  }

  Future<void> _importUrl() async {
    final ctl = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Импорт по ссылке'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://…/sqlsnap.json'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('Загрузить')),
        ],
      ),
    );
    ctl.dispose();
    if (url == null || url.isEmpty) return;
    setState(() => _busy = true);
    try {
      final r = await http.get(Uri.parse(url));
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
      await _importText(utf8.decode(r.bodyBytes));
    } catch (e) {
      if (mounted) toast(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _section(String title, IconData icon, List<Widget> children) => Card(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(icon, size: 20),
              const SizedBox(width: 8),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
            ]),
            const SizedBox(height: 10),
            ...children,
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Синхронизация'),
        bottom: _busy
            ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator())
            : null,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          ListenableBuilder(
            listenable: lan,
            builder: (context, _) => _section('Редактор по Wi‑Fi', Icons.wifi, [
              const Text(
                'Откройте ссылку в браузере на компьютере в той же сети — там можно '
                'полноценно править шаблоны и подключения и запускать запросы. '
                'Держите приложение открытым, пока работаете.',
              ),
              const SizedBox(height: 8),
              Row(children: [
                SizedBox(
                  width: 90,
                  child: TextField(
                    controller: _port,
                    enabled: !lan.running,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Порт', isDense: true),
                    onChanged: (v) {
                      final p = int.tryParse(v);
                      if (p != null && p > 0 && p < 65536) {
                        store.lanPort = p;
                        store.save();
                      }
                    },
                  ),
                ),
                const Spacer(),
                Switch(
                  value: lan.running,
                  onChanged: (v) => v ? lan.start() : lan.stop(),
                ),
              ]),
              if (lan.error != null)
                Text(lan.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              if (lan.running) ...[
                const SizedBox(height: 8),
                if (lan.urls.isEmpty) const Text('Не найден IP — подключитесь к Wi‑Fi'),
                for (final u in lan.urls)
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(children: [
                      Expanded(child: SelectableText(u, style: monoStyle.copyWith(fontSize: 15))),
                      IconButton(icon: const Icon(Icons.copy, size: 18), onPressed: () => copyText(context, u)),
                    ]),
                  ),
                const SizedBox(height: 6),
                Text('Ключ в ссылке меняется при каждом включении. Запросов: ${lan.requests}',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ]),
          ),
          _section('GitHub (файлы .sql)', Icons.code, [
            const Text(
              'Шаблоны хранятся в репозитории как .sql файлы с шапкой-комментарием — '
              'удобно править в IDE. Подпапки = папки шаблонов.',
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _repo,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Репозиторий (owner/name)', isDense: true),
            ),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _branch,
                  decoration: const InputDecoration(labelText: 'Ветка', isDense: true),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _dir,
                  decoration: const InputDecoration(labelText: 'Папка в репо', isDense: true),
                ),
              ),
            ]),
            TextField(
              controller: _token,
              obscureText: true,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Токен (fine-grained, Contents: read & write)',
                hintText: _tokenSaved ? 'сохранён — оставьте пустым' : null,
                floatingLabelBehavior: _tokenSaved ? FloatingLabelBehavior.always : null,
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _busy ? null : _pull,
                  icon: const Icon(Icons.download),
                  label: const Text('Pull'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _busy ? null : _push,
                  icon: const Icon(Icons.upload),
                  label: const Text('Push'),
                ),
              ),
            ]),
          ]),
          _section('Импорт / экспорт JSON', Icons.import_export, [
            const Text('Весь набор шаблонов и подключений одним JSON — через буфер обмена или по ссылке.'),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(onPressed: _export, icon: const Icon(Icons.copy), label: const Text('Экспорт')),
              OutlinedButton.icon(
                  onPressed: _importClipboard, icon: const Icon(Icons.paste), label: const Text('Из буфера')),
              OutlinedButton.icon(onPressed: _importUrl, icon: const Icon(Icons.link), label: const Text('По ссылке')),
            ]),
          ]),
          _section('Синтаксис шаблонов', Icons.help_outline, const [
            SelectableText(
              '{{client_id}} — переменная; тип задаётся в редакторе.\n'
              '[[ AND status = {{status}} ]] — блок выкидывается, если переменная пустая.\n'
              'IN ({{ids}}) — тип «Список»: значения через запятую или с новой строки.\n'
              'Даты по умолчанию: today, yesterday, today-7, month_start, now, now-2h.\n'
              'Строки экранируются автоматически под MySQL / PostgreSQL / ClickHouse.',
              style: monoStyle,
            ),
          ]),
        ],
      ),
    );
  }
}
