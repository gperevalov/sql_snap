import 'package:flutter/material.dart';

import '../models.dart';
import '../store.dart';
import '../template_engine.dart';
import 'common.dart';

class TemplateEditScreen extends StatefulWidget {
  final QueryTemplate? template;
  final String? initialSql;
  final String? initialConnection;

  const TemplateEditScreen({super.key, this.template, this.initialSql, this.initialConnection});

  @override
  State<TemplateEditScreen> createState() => _TemplateEditScreenState();
}

class _TemplateEditScreenState extends State<TemplateEditScreen> {
  final store = AppStore.instance;
  late QueryTemplate t;
  late final TextEditingController _name, _folder, _desc, _sql;
  final Map<String, Map<String, TextEditingController>> _varCtl = {};

  @override
  void initState() {
    super.initState();
    t = widget.template?.copy() ??
        QueryTemplate(
          sql: widget.initialSql ?? '',
          connection: widget.initialConnection ??
              (store.connections.isNotEmpty ? store.connections.first.name : ''),
        );
    if (widget.template == null) t.vars = syncVars(t.sql, t.vars);
    _name = TextEditingController(text: t.name);
    _folder = TextEditingController(text: t.folder);
    _desc = TextEditingController(text: t.description);
    _sql = TextEditingController(text: t.sql);
  }

  @override
  void dispose() {
    for (final c in [_name, _folder, _desc, _sql]) {
      c.dispose();
    }
    for (final m in _varCtl.values) {
      for (final c in m.values) {
        c.dispose();
      }
    }
    super.dispose();
  }

  TextEditingController _vc(TemplateVar v, String field, String init) {
    final m = _varCtl.putIfAbsent(v.name, () => {});
    return m.putIfAbsent(field, () => TextEditingController(text: init));
  }

  void _insertAtCursor(String text) {
    final sel = _sql.selection;
    final s = _sql.text;
    final start = sel.isValid ? sel.start : s.length;
    final end = sel.isValid ? sel.end : s.length;
    final ns = s.replaceRange(start, end, text);
    _sql.value = TextEditingValue(
      text: ns,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    _onSql(ns);
  }

  void _onSql(String v) {
    setState(() {
      t.sql = v;
      t.vars = syncVars(v, t.vars);
    });
  }

  void _save() {
    t.name = _name.text.trim();
    t.folder = _folder.text.trim();
    t.description = _desc.text.trim();
    t.sql = _sql.text;
    t.vars = syncVars(t.sql, t.vars);
    if (t.name.isEmpty) {
      toast(context, 'Укажите название', error: true);
      return;
    }
    store.upsertTemplate(t);
    Navigator.pop(context);
  }

  Future<void> _addVar() async {
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Новая переменная'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'например client_id'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Вставить')),
        ],
      ),
    );
    ctl.dispose();
    final n = (name ?? '').trim().replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
    if (n.isEmpty) return;
    _insertAtCursor('{{$n}}');
  }

  @override
  Widget build(BuildContext context) {
    final conns = store.connections.map((c) => c.name).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.template == null ? 'Новый шаблон' : 'Редактирование'),
        actions: [
          IconButton(icon: const Icon(Icons.check), tooltip: 'Сохранить', onPressed: _save),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 48),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Название *', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _folder,
                decoration: InputDecoration(
                  labelText: 'Папка',
                  border: const OutlineInputBorder(),
                  suffixIcon: store.folders.isEmpty
                      ? null
                      : PopupMenuButton<String>(
                          icon: const Icon(Icons.arrow_drop_down),
                          onSelected: (f) => _folder.text = f,
                          itemBuilder: (_) => [
                            for (final f in store.folders) PopupMenuItem(value: f, child: Text(f)),
                          ],
                        ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<String>(
                value: conns.contains(t.connection) ? t.connection : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Подключение', border: OutlineInputBorder()),
                items: [for (final c in conns) DropdownMenuItem(value: c, child: Text(c, overflow: TextOverflow.ellipsis))],
                onChanged: (v) => setState(() => t.connection = v ?? ''),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _desc,
            decoration: const InputDecoration(labelText: 'Описание', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _sql,
            minLines: 6,
            maxLines: 20,
            style: monoStyle,
            keyboardType: TextInputType.multiline,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'SQL',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
              helperText: '{{имя}} — переменная, [[ AND x = {{x}} ]] — блок пропускается, если x пустая',
              helperMaxLines: 2,
            ),
            onChanged: _onSql,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(spacing: 4, children: [
              TextButton.icon(onPressed: _addVar, icon: const Icon(Icons.add), label: const Text('{{переменная}}')),
              TextButton(onPressed: () => _insertAtCursor('[[  ]]'), child: const Text('[[ необяз. ]]')),
            ]),
          ),
          const SizedBox(height: 8),
          if (t.vars.isNotEmpty)
            Text('Переменные', style: Theme.of(context).textTheme.titleMedium),
          for (final v in t.vars) _varEditor(v),
        ],
      ),
    );
  }

  Widget _varEditor(TemplateVar v) {
    final hasOptions = v.type == 'select' || v.type == 'list';
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: ExpansionTile(
        title: Text(v.title),
        subtitle: Text('{{${v.name}}} • ${varTypeLabels[v.type]}${v.required ? ' • обязательная' : ''}'),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          TextField(
            controller: _vc(v, 'label', v.label),
            decoration: const InputDecoration(labelText: 'Подпись на форме', isDense: true),
            onChanged: (x) => setState(() => v.label = x),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: v.type,
            decoration: const InputDecoration(labelText: 'Тип', isDense: true),
            items: [
              for (final ty in varTypes) DropdownMenuItem(value: ty, child: Text(varTypeLabels[ty]!)),
            ],
            onChanged: (x) => setState(() => v.type = x ?? 'text'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _vc(v, 'default', v.defaultValue),
            decoration: InputDecoration(
              labelText: 'Значение по умолчанию',
              isDense: true,
              helperText: v.type == 'date' || v.type == 'datetime'
                  ? 'Можно: today, yesterday, today-7, month_start, now, now-2h'
                  : null,
            ),
            onChanged: (x) => setState(() => v.defaultValue = x),
          ),
          if (hasOptions) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _vc(v, 'options', v.options.join(', ')),
              decoration: InputDecoration(
                labelText: v.type == 'select' ? 'Варианты (через запятую)' : 'Варианты для выбора (необязательно)',
                isDense: true,
              ),
              onChanged: (x) => setState(() => v.options =
                  x.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList()),
            ),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'text', label: Text("'строки'")),
                ButtonSegment(value: 'number', label: Text('числа')),
              ],
              selected: {v.itemType},
              onSelectionChanged: (s) => setState(() => v.itemType = s.first),
            ),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Обязательная'),
            value: v.required,
            onChanged: (b) => setState(() => v.required = b),
          ),
        ],
      ),
    );
  }
}
