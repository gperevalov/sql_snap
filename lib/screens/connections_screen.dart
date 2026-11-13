import 'package:flutter/material.dart';

import '../db.dart';
import '../models.dart';
import '../store.dart';
import 'common.dart';

class ConnectionsScreen extends StatelessWidget {
  const ConnectionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Подключения')),
        floatingActionButton: FloatingActionButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ConnectionEditScreen()),
          ),
          child: const Icon(Icons.add),
        ),
        body: store.connections.isEmpty
            ? const Center(child: Text('Добавьте первое подключение кнопкой «+»'))
            : ListView(
                children: [
                  for (final c in store.connections)
                    ListTile(
                      leading: dbBadge(c.type),
                      title: Text(c.name),
                      subtitle: Text(
                        '${c.user}@${c.host}:${c.port}${c.database.isNotEmpty ? '/${c.database}' : ''}'
                        '${c.ssl ? ' • SSL' : ''}${c.readOnly ? ' • только чтение' : ''}',
                      ),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => ConnectionEditScreen(connection: c)),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class ConnectionEditScreen extends StatefulWidget {
  final DbConnection? connection;
  const ConnectionEditScreen({super.key, this.connection});

  @override
  State<ConnectionEditScreen> createState() => _ConnectionEditScreenState();
}

class _ConnectionEditScreenState extends State<ConnectionEditScreen> {
  final store = AppStore.instance;
  late DbConnection c;
  late final TextEditingController _name, _host, _port, _db, _user, _pwd;
  bool _hasPwd = false;
  bool _showPwd = false;
  bool _testing = false;

  bool get isNew => widget.connection == null;

  @override
  void initState() {
    super.initState();
    c = widget.connection?.copy() ?? DbConnection(type: DbType.postgres);
    _name = TextEditingController(text: c.name);
    _host = TextEditingController(text: c.host);
    _port = TextEditingController(text: '${c.port}');
    _db = TextEditingController(text: c.database);
    _user = TextEditingController(text: c.user);
    _pwd = TextEditingController();
    if (!isNew) {
      store.hasPassword(c.id).then((v) {
        if (mounted) setState(() => _hasPwd = v);
      });
    }
  }

  @override
  void dispose() {
    for (final x in [_name, _host, _port, _db, _user, _pwd]) {
      x.dispose();
    }
    super.dispose();
  }

  DbConnection _collect() {
    c.name = _name.text.trim();
    c.host = _host.text.trim();
    c.port = int.tryParse(_port.text.trim()) ?? defaultPort(c.type, ssl: c.ssl);
    c.database = _db.text.trim();
    c.user = _user.text.trim();
    return c;
  }

  Future<void> _save() async {
    _collect();
    if (c.name.isEmpty || c.host.isEmpty) {
      toast(context, 'Нужны название и хост', error: true);
      return;
    }
    final dup = store.connectionByName(c.name);
    if (dup != null && dup.id != c.id) {
      toast(context, 'Подключение с таким названием уже есть', error: true);
      return;
    }
    await store.upsertConnection(c, password: _pwd.text.isEmpty ? null : _pwd.text);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _test() async {
    _collect();
    setState(() => _testing = true);
    try {
      final pwd = _pwd.text.isNotEmpty ? _pwd.text : (isNew ? '' : await store.password(c.id));
      final r = await runQuery(c, pwd, 'SELECT 1');
      if (mounted) toast(context, 'Подключение работает • ${r.elapsed.inMilliseconds} мс');
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Не удалось подключиться'),
            content: SingleChildScrollView(child: SelectableText('$e', style: monoStyle)),
            actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  void _setType(DbType t) {
    setState(() {
      final wasDefault = int.tryParse(_port.text) == defaultPort(c.type, ssl: c.ssl);
      c.type = t;
      if (wasDefault || _port.text.isEmpty) _port.text = '${defaultPort(t, ssl: c.ssl)}';
    });
  }

  void _setSsl(bool v) {
    setState(() {
      final wasDefault = int.tryParse(_port.text) == defaultPort(c.type, ssl: c.ssl);
      c.ssl = v;
      if (wasDefault) _port.text = '${defaultPort(c.type, ssl: v)}';
    });
  }

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 12);
    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? 'Новое подключение' : c.name),
        actions: [
          if (!isNew)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                final n = store.templates.where((t) => t.connection == c.name).length;
                final ok = await confirm(
                  context,
                  'Удалить подключение?',
                  n > 0 ? 'Его используют шаблоны: $n. Сами шаблоны останутся.' : c.name,
                  ok: 'Удалить',
                  danger: true,
                );
                if (!ok) return;
                await store.deleteConnection(c.id);
                if (context.mounted) Navigator.pop(context);
              },
            ),
          IconButton(icon: const Icon(Icons.check), onPressed: _save),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<DbType>(
            segments: const [
              ButtonSegment(value: DbType.postgres, label: Text('Postgres')),
              ButtonSegment(value: DbType.mysql, label: Text('MySQL')),
              ButtonSegment(value: DbType.clickhouse, label: Text('ClickHouse')),
            ],
            selected: {c.type},
            onSelectionChanged: (s) => _setType(s.first),
          ),
          gap,
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Название *',
              helperText: 'По нему шаблоны ссылаются на подключение',
              border: OutlineInputBorder(),
            ),
          ),
          gap,
          Row(children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _host,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Хост *', border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _port,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Порт', border: OutlineInputBorder()),
              ),
            ),
          ]),
          gap,
          TextField(
            controller: _db,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'База данных', border: OutlineInputBorder()),
          ),
          gap,
          TextField(
            controller: _user,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Пользователь', border: OutlineInputBorder()),
          ),
          gap,
          TextField(
            controller: _pwd,
            obscureText: !_showPwd,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Пароль',
              hintText: _hasPwd ? '•••••• (сохранён, оставьте пустым)' : null,
              floatingLabelBehavior: _hasPwd ? FloatingLabelBehavior.always : null,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_showPwd ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _showPwd = !_showPwd),
              ),
            ),
          ),
          SwitchListTile(
            title: Text(c.type == DbType.clickhouse ? 'HTTPS' : 'SSL/TLS'),
            subtitle: Text(c.type == DbType.mysql
                ? 'Для MySQL 8 (caching_sha2_password) обычно нужно включить'
                : c.type == DbType.clickhouse
                    ? 'HTTP-интерфейс: 8123, HTTPS: 8443'
                    : 'Без проверки сертификата'),
            value: c.ssl,
            onChanged: _setSsl,
          ),
          SwitchListTile(
            title: const Text('Только чтение'),
            subtitle: const Text('Запретить INSERT/UPDATE/DELETE/DDL'),
            value: c.readOnly,
            onChanged: (v) => setState(() => c.readOnly = v),
          ),
          gap,
          OutlinedButton.icon(
            onPressed: _testing ? null : _test,
            icon: _testing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.network_check),
            label: const Text('Проверить подключение'),
          ),
        ],
      ),
    );
  }
}
