import 'package:flutter/material.dart';

import '../models.dart';
import '../store.dart';
import '../template_engine.dart';
import 'common.dart';
import 'template_edit_screen.dart';

class RunTemplateScreen extends StatefulWidget {
  final String templateId;
  const RunTemplateScreen({super.key, required this.templateId});

  @override
  State<RunTemplateScreen> createState() => _RunTemplateScreenState();
}

class _RunTemplateScreenState extends State<RunTemplateScreen> {
  final store = AppStore.instance;
  final Map<String, TextEditingController> _ctl = {};
  final Map<String, String> _values = {};
  late Set<String> _optional;
  String? _connName;
  bool _showSql = false;

  QueryTemplate? get t => store.templateById(widget.templateId);

  @override
  void initState() {
    super.initState();
    _init();
  }

  void _init() {
    final tpl = t;
    if (tpl == null) return;
    _connName ??= tpl.connection;
    _optional = optionalVarNames(tpl.sql);
    for (final v in tpl.vars) {
      if (_values.containsKey(v.name)) continue;
      final def = resolveDefault(v);
      _values[v.name] = v.type == 'bool' && def.isEmpty ? 'false' : def;
      _ctl[v.name] = TextEditingController(text: _values[v.name]);
    }
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _set(String name, String value, {bool updateField = true}) {
    setState(() => _values[name] = value);
    if (updateField) {
      final c = _ctl[name];
      if (c != null && c.text != value) c.text = value;
    }
  }

  DbConnection? get _conn => _connName == null ? null : store.connectionByName(_connName!);

  String? _render() {
    final tpl = t!;
    try {
      return renderSql(tpl.sql, tpl.vars, _values, _conn?.type ?? DbType.mysql);
    } on RenderException catch (e) {
      toast(context, e.message, error: true);
      return null;
    }
  }

  Future<void> _run() async {
    FocusScope.of(context).unfocus();
    final conn = _conn;
    if (conn == null) {
      toast(context, 'Выберите подключение', error: true);
      return;
    }
    final sql = _render();
    if (sql == null) return;
    store.rememberValues(t!.id, _values);
    await executeAndShow(context, conn, sql, title: t!.name);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final tpl = t;
        if (tpl == null) {
          return Scaffold(appBar: AppBar(), body: const Center(child: Text('Шаблон удалён')));
        }
        _init();
        String preview;
        try {
          preview = renderSql(tpl.sql, tpl.vars, _values, _conn?.type ?? DbType.mysql);
        } catch (e) {
          preview = '-- $e\n${tpl.sql}';
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(tpl.name),
            actions: [
              IconButton(
                tooltip: store.isFavorite(tpl.id) ? 'Убрать из избранного' : 'В избранное',
                icon: store.isFavorite(tpl.id)
                    ? const Icon(Icons.star, color: Colors.amber)
                    : const Icon(Icons.star_border),
                onPressed: () => store.toggleFavorite(tpl.id),
              ),
              IconButton(
                tooltip: 'Редактировать',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => TemplateEditScreen(template: tpl)),
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'pin') pinTemplateShortcut(context, tpl);
                  if (v == 'preset') _savePreset(tpl);
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'pin', child: Text('Ярлык на рабочий стол')),
                  if (tpl.vars.isNotEmpty)
                    const PopupMenuItem(value: 'preset', child: Text('Сохранить значения как набор')),
                ],
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
            children: [
              if (tpl.description.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(tpl.description, style: Theme.of(context).textTheme.bodyMedium),
                ),
              DropdownButtonFormField<String>(
                value: store.connections.any((c) => c.name == _conn?.name) ? _conn!.name : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Подключение', border: OutlineInputBorder()),
                items: [
                  for (final c in store.connections)
                    DropdownMenuItem(
                      value: c.name,
                      child: Row(children: [dbBadge(c.type), const SizedBox(width: 8), Text(c.name)]),
                    ),
                ],
                onChanged: (v) => setState(() => _connName = v),
              ),
              const SizedBox(height: 12),
              if (tpl.vars.isNotEmpty) _presets(tpl),
              const SizedBox(height: 4),
              for (final v in tpl.vars) ...[
                _field(tpl, v),
                const SizedBox(height: 14),
              ],
              Card(
                margin: EdgeInsets.zero,
                child: Column(children: [
                  ListTile(
                    dense: true,
                    title: const Text('Итоговый SQL'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        icon: const Icon(Icons.copy, size: 18),
                        onPressed: () => copyText(context, preview, 'SQL скопирован'),
                      ),
                      Icon(_showSql ? Icons.expand_less : Icons.expand_more),
                    ]),
                    onTap: () => setState(() => _showSql = !_showSql),
                  ),
                  if (_showSql)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: SelectableText(preview, style: monoStyle),
                      ),
                    ),
                ]),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _run,
            icon: Icon(isWriteQuery(tpl.sql) ? Icons.warning_amber : Icons.play_arrow),
            label: const Text('Выполнить'),
          ),
        );
      },
    );
  }

  /// Named sets of values: tap to fill all fields at once, × to delete, «+» to save current values.
  Widget _presets(QueryTemplate tpl) {
    final presets = store.presetsOf(tpl.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(spacing: 6, runSpacing: 0, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text('Наборы:', style: Theme.of(context).textTheme.bodySmall),
        for (final e in presets.entries)
          InputChip(
            visualDensity: VisualDensity.compact,
            avatar: const Icon(Icons.bolt, size: 16),
            label: Text(e.key),
            onPressed: () => _applyPreset(tpl, e.key, e.value),
            onDeleted: () async {
              if (await confirm(context, 'Удалить набор?', e.key, ok: 'Удалить', danger: true)) {
                store.deletePreset(tpl.id, e.key);
              }
            },
          ),
        ActionChip(
          visualDensity: VisualDensity.compact,
          avatar: const Icon(Icons.add, size: 16),
          label: Text(presets.isEmpty ? 'Сохранить текущие значения' : 'Сохранить'),
          onPressed: () => _savePreset(tpl),
        ),
      ]),
    );
  }

  void _applyPreset(QueryTemplate tpl, String name, Map<String, String> values) {
    for (final v in tpl.vars) {
      final value = values[v.name];
      if (value != null) _set(v.name, value);
    }
    toast(context, 'Подставлен набор «$name»');
  }

  Future<void> _savePreset(QueryTemplate tpl) async {
    final suggestion = tpl.vars.map((v) => _values[v.name] ?? '').firstWhere(
          (x) => x.trim().isNotEmpty && x.length <= 30,
          orElse: () => '',
        );
    final ctl = TextEditingController(text: suggestion);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Сохранить набор значений'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Название', hintText: 'например «Ромашка, неделя»'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Сохранить')),
        ],
      ),
    );
    ctl.dispose();
    final n = (name ?? '').trim();
    if (n.isEmpty || !mounted) return;
    final existed = store.presetsOf(tpl.id).containsKey(n);
    store.savePreset(tpl.id, n, {for (final v in tpl.vars) v.name: _values[v.name] ?? ''});
    toast(context, existed ? 'Набор «$n» обновлён' : 'Набор «$n» сохранён');
  }

  Widget _recent(QueryTemplate tpl, TemplateVar v) {
    final recent = store.recentValues(tpl.id, v.name).where((x) => x != _values[v.name]).take(5).toList();
    if (recent.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 6,
        runSpacing: -6,
        children: [
          for (final r in recent)
            ActionChip(
              visualDensity: VisualDensity.compact,
              label: Text(r.length > 30 ? '${r.substring(0, 30)}…' : r, style: const TextStyle(fontSize: 12)),
              onPressed: () => _set(v.name, r),
            ),
        ],
      ),
    );
  }

  Widget _field(QueryTemplate tpl, TemplateVar v) {
    final optional = _optional.contains(v.name) && !v.required;
    final label = '${v.title}${v.required ? ' *' : ''}${optional ? ' (необязательно)' : ''}';
    final ctl = _ctl[v.name]!;
    InputDecoration deco({Widget? suffix, String? hint}) => InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
          suffixIcon: suffix,
        );
    Widget clearBtn() => IconButton(
          icon: const Icon(Icons.clear, size: 18),
          onPressed: () => _set(v.name, ''),
        );
    // Clear button plus, if the author listed options, a dropdown with them.
    Widget suffixButtons() => Row(mainAxisSize: MainAxisSize.min, children: [
          if (v.choices.isNotEmpty) _optionsMenu(v),
          clearBtn(),
        ]);

    switch (v.type) {
      case 'bool':
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(v.title),
          value: _values[v.name] == 'true',
          onChanged: (b) => _set(v.name, b ? 'true' : 'false'),
        );
      case 'select':
        final opts = v.choices;
        final cur = _values[v.name] ?? '';
        return DropdownButtonFormField<String>(
          value: opts.contains(cur) ? cur : (cur.isEmpty && !v.required ? '' : null),
          isExpanded: true,
          decoration: deco(),
          items: [
            if (!v.required) const DropdownMenuItem(value: '', child: Text('— не задано —')),
            for (final o in opts) DropdownMenuItem(value: o, child: Text(o)),
          ],
          onChanged: (x) => _set(v.name, x ?? ''),
        );
      case 'list':
        if (v.choices.isNotEmpty) {
          final selected = _splitList(_values[v.name]);
          return InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () => _pickMany(v),
            child: InputDecorator(
              isEmpty: selected.isEmpty,
              decoration: deco(suffix: const Icon(Icons.arrow_drop_down)),
              child: Text(selected.join(', ')),
            ),
          );
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: ctl,
            minLines: 1,
            maxLines: 6,
            keyboardType: v.itemType == 'number' ? TextInputType.multiline : TextInputType.multiline,
            decoration: deco(
              hint: 'через запятую или с новой строки',
              suffix: clearBtn(),
            ),
            onChanged: (x) => _set(v.name, x, updateField: false),
          ),
          _recent(tpl, v),
        ]);
      case 'date':
      case 'datetime':
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: ctl,
            keyboardType: TextInputType.datetime,
            decoration: deco(
              hint: v.type == 'date' ? 'ГГГГ-ММ-ДД' : 'ГГГГ-ММ-ДД ЧЧ:ММ:СС',
              suffix: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(icon: const Icon(Icons.calendar_month), onPressed: () => _pickDate(v)),
                clearBtn(),
              ]),
            ),
            onChanged: (x) => _set(v.name, x, updateField: false),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(spacing: 6, runSpacing: -6, children: [
              for (final q in const [
                ['Сегодня', 'today'],
                ['Вчера', 'yesterday'],
                ['−7 дн', 'today-7'],
                ['−30 дн', 'today-30'],
                ['Нач. месяца', 'month_start'],
              ])
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(q[0], style: const TextStyle(fontSize: 12)),
                  onPressed: () => _set(
                    v.name,
                    resolveDefault(TemplateVar(name: v.name, type: v.type, defaultValue: q[1])),
                  ),
                ),
            ]),
          ),
        ]);
      case 'number':
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: ctl,
            keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
            decoration: deco(suffix: suffixButtons()),
            onChanged: (x) => _set(v.name, x, updateField: false),
          ),
          _recent(tpl, v),
        ]);
      default:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: ctl,
            decoration: deco(suffix: suffixButtons()),
            onChanged: (x) => _set(v.name, x, updateField: false),
          ),
          _recent(tpl, v),
        ]);
    }
  }

  /// Dropdown with the author's options for free-input fields: pick one or keep typing your own.
  Widget _optionsMenu(TemplateVar v) => PopupMenuButton<String>(
        tooltip: 'Варианты',
        icon: const Icon(Icons.arrow_drop_down),
        onSelected: (o) => _set(v.name, o),
        itemBuilder: (_) => [
          for (final o in v.choices)
            CheckedPopupMenuItem(value: o, checked: _values[v.name] == o, child: Text(o)),
        ],
      );

  static List<String> _splitList(String? raw) => (raw ?? '')
      .split(RegExp(r'[,\n;]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toSet()
      .toList();

  /// Multi-select dropdown for `list` variables with options.
  /// Values that are not among the options (e.g. from history) stay in the list so they can be unticked.
  Future<void> _pickMany(TemplateVar v) async {
    FocusScope.of(context).unfocus();
    final current = _splitList(_values[v.name]);
    final items = [...v.choices, ...current.where((x) => !v.choices.contains(x))];
    final selected = current.toSet();
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(v.title),
          contentPadding: const EdgeInsets.only(top: 12),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(shrinkWrap: true, children: [
              for (final o in items)
                CheckboxListTile(
                  dense: true,
                  value: selected.contains(o),
                  title: Text(o),
                  onChanged: (b) => setDialog(() => b == true ? selected.add(o) : selected.remove(o)),
                ),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () => setDialog(() => selected.length == items.length
                  ? selected.clear()
                  : selected.addAll(items)),
              child: Text(selected.length == items.length ? 'Снять все' : 'Выбрать все'),
            ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(ctx, selected), child: const Text('Готово')),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    _set(v.name, items.where(result.contains).join(','));
  }

  Future<void> _pickDate(TemplateVar v) async {
    final cur = DateTime.tryParse((_values[v.name] ?? '').replaceFirst(' ', 'T')) ?? DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: cur,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d == null || !mounted) return;
    if (v.type == 'date') {
      _set(v.name, fmtDate(d));
      return;
    }
    final tm = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(cur));
    if (!mounted) return;
    final dt = DateTime(d.year, d.month, d.day, tm?.hour ?? 0, tm?.minute ?? 0);
    _set(v.name, fmtDateTime(dt));
  }
}
