import 'package:flutter/material.dart';

import '../models.dart';
import '../store.dart';
import 'common.dart';
import 'run_template_screen.dart';
import 'template_edit_screen.dart';

class TemplatesScreen extends StatefulWidget {
  const TemplatesScreen({super.key});

  @override
  State<TemplatesScreen> createState() => _TemplatesScreenState();
}

class _TemplatesScreenState extends State<TemplatesScreen> {
  final store = AppStore.instance;
  String _q = '';
  final Set<String> _collapsed = {};

  void _edit(QueryTemplate? t) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TemplateEditScreen(template: t)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final q = _q.toLowerCase();
        final list = store.templates.where((t) {
          if (q.isEmpty) return true;
          return t.name.toLowerCase().contains(q) ||
              t.folder.toLowerCase().contains(q) ||
              t.description.toLowerCase().contains(q) ||
              t.sql.toLowerCase().contains(q);
        }).toList();
        final groups = <String, List<QueryTemplate>>{};
        for (final t in list) {
          groups.putIfAbsent(t.folder, () => []).add(t);
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text('Шаблоны'),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(56),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: SearchBar(
                  hintText: 'Поиск по названию и SQL',
                  leading: const Icon(Icons.search),
                  elevation: const WidgetStatePropertyAll<double>(0.0),
                  onChanged: (v) => setState(() => _q = v),
                ),
              ),
            ),
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: () => _edit(null),
            child: const Icon(Icons.add),
          ),
          body: store.templates.isEmpty
              ? const _EmptyHint()
              : ListView(
                  padding: const EdgeInsets.only(bottom: 88),
                  children: [
                    for (final e in groups.entries) ...[
                      if (groups.length > 1 || e.key.isNotEmpty)
                        InkWell(
                          onTap: () => setState(() {
                            _collapsed.contains(e.key) ? _collapsed.remove(e.key) : _collapsed.add(e.key);
                          }),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                            child: Row(children: [
                              Icon(
                                _collapsed.contains(e.key) ? Icons.chevron_right : Icons.expand_more,
                                size: 18,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                e.key.isEmpty ? 'Без папки' : e.key,
                                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                      color: Theme.of(context).colorScheme.primary,
                                    ),
                              ),
                              const SizedBox(width: 6),
                              Text('${e.value.length}', style: Theme.of(context).textTheme.bodySmall),
                            ]),
                          ),
                        ),
                      if (!_collapsed.contains(e.key) || q.isNotEmpty)
                        for (final t in e.value) _tile(t),
                    ],
                  ],
                ),
        );
      },
    );
  }

  Widget _tile(QueryTemplate t) {
    final conn = store.connectionByName(t.connection);
    return ListTile(
      leading: conn != null
          ? dbBadge(conn.type)
          : const Icon(Icons.link_off, size: 20, color: Colors.grey),
      title: Text(t.name),
      subtitle: Text(
        [
          if (t.description.isNotEmpty) t.description,
          if (t.vars.isNotEmpty) t.vars.map((v) => v.title).join(', '),
          if (conn == null) 'нет подключения «${t.connection}»',
        ].join(' • '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => RunTemplateScreen(templateId: t.id)),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (v) async {
          switch (v) {
            case 'edit':
              _edit(t);
              break;
            case 'dup':
              final c = t.copy()
                ..id = newId()
                ..sourcePath = null
                ..name = '${t.name} (копия)';
              store.upsertTemplate(c);
              break;
            case 'del':
              if (await confirm(context, 'Удалить шаблон?', t.name, ok: 'Удалить', danger: true)) {
                store.deleteTemplate(t.id);
              }
              break;
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('Редактировать')),
          PopupMenuItem(value: 'dup', child: Text('Дублировать')),
          PopupMenuItem(value: 'del', child: Text('Удалить')),
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Text(
          'Шаблонов пока нет.\n\n'
          '1. Добавьте подключение во вкладке «Базы».\n'
          '2. Создайте шаблон кнопкой «+» — или удобнее с компьютера: '
          'вкладка «Синхр.» → веб-редактор по Wi‑Fi или GitHub.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
