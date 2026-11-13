import 'package:flutter/material.dart';

import '../store.dart';
import 'common.dart';
import 'template_edit_screen.dart';

class ConsoleScreen extends StatefulWidget {
  const ConsoleScreen({super.key});

  @override
  State<ConsoleScreen> createState() => _ConsoleScreenState();
}

class _ConsoleScreenState extends State<ConsoleScreen> {
  final store = AppStore.instance;
  final _sql = TextEditingController();
  String? _connId;
  final List<String> _history = [];

  @override
  void dispose() {
    _sql.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    FocusScope.of(context).unfocus();
    final conn = _connId == null ? null : store.connectionById(_connId!);
    if (conn == null) {
      toast(context, 'Выберите подключение', error: true);
      return;
    }
    final sql = _sql.text.trim();
    if (sql.isEmpty) return;
    setState(() {
      _history.remove(sql);
      _history.insert(0, sql);
      if (_history.length > 30) _history.removeLast();
    });
    await executeAndShow(context, conn, sql, title: conn.name);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        if (_connId == null || store.connectionById(_connId!) == null) {
          _connId = store.connections.isNotEmpty ? store.connections.first.id : null;
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text('SQL'),
            actions: [
              IconButton(
                tooltip: 'Сохранить как шаблон',
                icon: const Icon(Icons.bookmark_add_outlined),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TemplateEditScreen(
                      initialSql: _sql.text,
                      initialConnection: store.connectionById(_connId ?? '')?.name,
                    ),
                  ),
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.history),
                tooltip: 'История',
                enabled: _history.isNotEmpty,
                onSelected: (s) => _sql.text = s,
                itemBuilder: (_) => [
                  for (final h in _history)
                    PopupMenuItem(
                      value: h,
                      child: Text(h, maxLines: 2, overflow: TextOverflow.ellipsis, style: monoStyle),
                    ),
                ],
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
            children: [
              DropdownButtonFormField<String>(
                value: _connId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Подключение', border: OutlineInputBorder()),
                items: [
                  for (final c in store.connections)
                    DropdownMenuItem(
                      value: c.id,
                      child: Row(children: [dbBadge(c.type), const SizedBox(width: 8), Text(c.name)]),
                    ),
                ],
                onChanged: (v) => setState(() => _connId = v),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _sql,
                minLines: 8,
                maxLines: 24,
                style: monoStyle,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.multiline,
                decoration: const InputDecoration(
                  hintText: 'SELECT …',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 6, children: [
                for (final s in const ['SELECT * FROM ', 'LIMIT 100', 'WHERE ', 'ORDER BY ', 'COUNT(*)', 'SHOW TABLES'])
                  ActionChip(
                    label: Text(s.trim(), style: const TextStyle(fontSize: 12)),
                    onPressed: () {
                      final sel = _sql.selection;
                      final pos = sel.isValid ? sel.start : _sql.text.length;
                      final end = sel.isValid ? sel.end : _sql.text.length;
                      final ns = _sql.text.replaceRange(pos, end, s);
                      _sql.value = TextEditingValue(
                        text: ns,
                        selection: TextSelection.collapsed(offset: pos + s.length),
                      );
                    },
                  ),
              ]),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _run,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Выполнить'),
          ),
        );
      },
    );
  }
}
