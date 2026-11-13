import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../db.dart';
import '../export.dart';
import '../models.dart';
import '../store.dart';
import '../template_engine.dart';
import 'common.dart';

class ResultsScreen extends StatefulWidget {
  final QueryResult result;
  final String title;
  final String sql;

  /// Where the query ran. When set (and the query only reads), pull-to-refresh re-runs it.
  final DbConnection? connection;

  /// Shown under the stats line, e.g. «из истории, 14:05».
  final String? note;

  const ResultsScreen({
    super.key,
    required this.result,
    required this.title,
    required this.sql,
    this.connection,
    this.note,
  });

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  final _hScroll = ScrollController();
  final _refreshKey = GlobalKey<RefreshIndicatorState>();
  late QueryResult r = widget.result;
  String? _note;
  String _filter = '';
  bool _cards = false;
  late List<double> _widths;

  /// Column indexes hidden by the user.
  final Set<int> _hidden = {};
  int? _sortCol;
  bool _sortAsc = true;

  bool get _canRerun => widget.connection != null && !isWriteQuery(widget.sql);

  @override
  void initState() {
    super.initState();
    _note = widget.note;
    _applyResult(r, firstTime: true);
  }

  @override
  void dispose() {
    _hScroll.dispose();
    super.dispose();
  }

  void _applyResult(QueryResult res, {bool firstTime = false}) {
    // Keep user's view settings if the columns are the same after a refresh.
    final sameColumns = !firstTime && _listEquals(res.columns, r.columns);
    r = res;
    if (!sameColumns) {
      _hidden.clear();
      _sortCol = null;
    }
    _widths = List.generate(r.columns.length, (i) {
      var len = r.columns[i].length + 2;
      for (final row in r.rows.take(200)) {
        final v = row[i];
        len = max(len, v == null ? 4 : min(v.length, 60));
      }
      return (len * 8.0 + 24).clamp(56.0, 360.0).toDouble();
    });
    if (firstTime) _cards = r.columns.length > 6 && r.rows.length <= 50;
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ---------- view: visible columns, filter, sort ----------

  List<int> get _visibleCols => [
        for (var i = 0; i < r.columns.length; i++)
          if (!_hidden.contains(i)) i
      ];

  List<List<String?>> get _rows {
    var rows = r.rows;
    if (_filter.isNotEmpty) {
      final f = _filter.toLowerCase();
      rows = rows.where((row) => row.any((v) => v != null && v.toLowerCase().contains(f))).toList();
    }
    final col = _sortCol;
    if (col != null) {
      rows = List.of(rows)..sort((a, b) => _compareCells(a[col], b[col]) * (_sortAsc ? 1 : -1));
    }
    return rows;
  }

  /// NULLs last, numbers numerically, the rest as case-insensitive text.
  static int _compareCells(String? a, String? b) {
    if (a == null || b == null) return a == null ? (b == null ? 0 : 1) : -1;
    final na = _num(a), nb = _num(b);
    if (na != null && nb != null) return na.compareTo(nb);
    return a.toLowerCase().compareTo(b.toLowerCase());
  }

  static double? _num(String? v) => v == null ? null : double.tryParse(v.trim().replaceAll(' ', ''));

  /// What is on screen right now — used for copy and share.
  QueryResult get _currentView => r.view(_visibleCols, _rows);

  // ---------- actions ----------

  Future<void> _refresh() async {
    final conn = widget.connection;
    if (conn == null) return;
    try {
      final res = await runQuery(conn, await AppStore.instance.password(conn.id), widget.sql);
      rememberRun(conn, widget.sql, widget.title, res);
      if (!mounted) return;
      setState(() {
        _applyResult(res);
        _note = null;
      });
      toast(context, 'Обновлено: ${res.rows.length} строк');
    } catch (e) {
      if (mounted) showErrorDialog(context, e.toString());
    }
  }

  Future<void> _share(ShareFormat f) async {
    try {
      final outcome = await shareResult(_currentView, widget.title, f);
      if (outcome == ShareOutcome.sentAsFile && mounted) {
        toast(context, 'Текст слишком большой для сообщения — отправлен файлом .txt');
      }
    } catch (e) {
      // Platform errors carry a whole Java stack trace — the first line is enough.
      final msg = (e is PlatformException ? (e.message ?? e.code) : e.toString()).split('\n').first;
      if (mounted) toast(context, 'Не удалось поделиться: $msg', error: true);
    }
  }

  void _sortBy(int col, bool? asc) => setState(() {
        if (asc == null) {
          _sortCol = null;
        } else {
          _sortCol = col;
          _sortAsc = asc;
        }
      });

  Future<void> _chooseColumns() async {
    final hidden = Set<int>.of(_hidden);
    final res = await showDialog<Set<int>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text('Колонки'),
          contentPadding: const EdgeInsets.only(top: 12),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(shrinkWrap: true, children: [
              for (var i = 0; i < r.columns.length; i++)
                CheckboxListTile(
                  dense: true,
                  value: !hidden.contains(i),
                  title: Text(r.columns[i]),
                  onChanged: (b) => setDialog(() => b == true ? hidden.remove(i) : hidden.add(i)),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => setDialog(hidden.clear), child: const Text('Показать все')),
            FilledButton(onPressed: () => Navigator.pop(ctx, hidden), child: const Text('Готово')),
          ],
        ),
      ),
    );
    if (res == null) return;
    if (res.length == r.columns.length) {
      if (mounted) toast(context, 'Нужна хотя бы одна колонка', error: true);
      return;
    }
    setState(() {
      _hidden
        ..clear()
        ..addAll(res);
    });
  }

  Future<void> _pickColumn(String title, void Function(int col) then) async {
    final col = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => ListView(shrinkWrap: true, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(title, style: Theme.of(ctx).textTheme.titleMedium),
        ),
        for (final i in _visibleCols)
          ListTile(dense: true, title: Text(r.columns[i]), onTap: () => Navigator.pop(ctx, i)),
      ]),
    );
    if (col != null) then(col);
  }

  /// Menu for one column: sort, totals, copy values, hide.
  void _columnMenu(int col) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        void act(VoidCallback f) {
          Navigator.pop(ctx);
          f();
        }

        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(r.columns[col], style: Theme.of(ctx).textTheme.titleMedium),
            ),
            ListTile(
              leading: const Icon(Icons.arrow_upward),
              title: const Text('Сортировать по возрастанию'),
              selected: _sortCol == col && _sortAsc,
              onTap: () => act(() => _sortBy(col, true)),
            ),
            ListTile(
              leading: const Icon(Icons.arrow_downward),
              title: const Text('Сортировать по убыванию'),
              selected: _sortCol == col && !_sortAsc,
              onTap: () => act(() => _sortBy(col, false)),
            ),
            if (_sortCol != null)
              ListTile(
                leading: const Icon(Icons.sort),
                title: const Text('Без сортировки'),
                onTap: () => act(() => _sortBy(col, null)),
              ),
            ListTile(
              leading: const Icon(Icons.functions),
              title: const Text('Итоги: сумма, среднее, мин/макс'),
              onTap: () => act(() => _showStats(col)),
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Копировать значения через запятую'),
              subtitle: const Text('удобно вставить в поле-список шаблона'),
              onTap: () => act(() {
                final vals = _rows.map((row) => row[col]).whereType<String>().toSet().join(', ');
                copyText(context, vals, 'Скопированы значения колонки');
              }),
            ),
            if (_visibleCols.length > 1)
              ListTile(
                leading: const Icon(Icons.visibility_off_outlined),
                title: const Text('Скрыть колонку'),
                onTap: () => act(() => setState(() => _hidden.add(col))),
              ),
          ]),
        );
      },
    );
  }

  void _showStats(int col) {
    final values = _rows.map((row) => row[col]).toList();
    final nonNull = values.whereType<String>().toList();
    final nums = nonNull.map(_num).whereType<double>().toList();
    final counts = <String, int>{};
    for (final v in nonNull) {
      counts[v] = (counts[v] ?? 0) + 1;
    }
    final top = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    final lines = <List<String>>[
      ['Строк', '${values.length}'],
      ['Не NULL', '${nonNull.length}'],
      ['Уникальных', '${counts.length}'],
      if (nums.isNotEmpty) ...[
        if (nums.length != nonNull.length) ['Чисел', '${nums.length}'],
        ['Сумма', _fmtNum(nums.reduce((a, b) => a + b))],
        ['Среднее', _fmtNum(nums.reduce((a, b) => a + b) / nums.length)],
        ['Минимум', _fmtNum(nums.reduce(min))],
        ['Максимум', _fmtNum(nums.reduce(max))],
      ],
    ];
    final text = lines.map((l) => '${l[0]}: ${l[1]}').join('\n');

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
          Text('Итоги: ${r.columns[col]}', style: Theme.of(ctx).textTheme.titleMedium),
          if (_filter.isNotEmpty)
            Text('по отфильтрованным строкам', style: Theme.of(ctx).textTheme.bodySmall),
          const SizedBox(height: 8),
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Expanded(child: Text(l[0])),
                SelectableText(l[1], style: monoStyle.copyWith(fontWeight: FontWeight.bold)),
              ]),
            ),
          if (top.isNotEmpty && top.first.value > 1) ...[
            const SizedBox(height: 12),
            Text('Частые значения', style: Theme.of(ctx).textTheme.labelLarge),
            for (final e in top.take(5))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Expanded(child: Text(e.key, style: monoStyle, overflow: TextOverflow.ellipsis)),
                  Text('× ${e.value}'),
                ]),
              ),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => copyText(ctx, text, 'Итоги скопированы'),
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Копировать'),
            ),
          ),
        ]),
      ),
    );
  }

  static String _fmtNum(double v) {
    if (v == v.roundToDouble() && v.abs() < 1e15) return v.toStringAsFixed(0);
    var s = v.toStringAsFixed(4);
    s = s.replaceFirst(RegExp(r'0+$'), '');
    return s.endsWith('.') ? s.substring(0, s.length - 1) : s;
  }

  void _showRow(List<String?> row) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.95,
        builder: (ctx, sc) => ListView.separated(
          controller: sc,
          itemCount: r.columns.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (ctx, i) => ListTile(
            dense: true,
            title: Text(r.columns[i], style: Theme.of(ctx).textTheme.labelMedium),
            subtitle: SelectableText(row[i] ?? 'NULL', style: monoStyle),
            trailing: IconButton(
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () => copyText(ctx, row[i] ?? ''),
            ),
          ),
        ),
      ),
    );
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final cols = _visibleCols;
    final cs = Theme.of(context).colorScheme;
    final totalWidth = cols.fold<double>(0, (a, i) => a + _widths[i]) + 40;
    final info = [
      '${r.rows.length}${r.truncated ? '+' : ''} строк',
      '${r.elapsed.inMilliseconds} мс',
      if (_filter.isNotEmpty) 'найдено ${rows.length}',
      if (_hidden.isNotEmpty) 'скрыто колонок ${_hidden.length}',
      if (_note != null) _note!,
    ].join(' • ');

    Widget body = _cards ? _cardList(rows, cols) : _table(rows, cols, totalWidth, cs);
    if (_canRerun) {
      body = RefreshIndicator(
        key: _refreshKey,
        onRefresh: _refresh,
        // The vertical list sits inside a horizontal scroll in table mode.
        notificationPredicate: (n) => n.metrics.axis == Axis.vertical,
        child: body,
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
          if (_canRerun)
            IconButton(
              tooltip: 'Выполнить ещё раз',
              icon: const Icon(Icons.refresh),
              onPressed: () => _refreshKey.currentState?.show(),
            ),
          IconButton(
            tooltip: _cards ? 'Таблица' : 'Карточки',
            icon: Icon(_cards ? Icons.table_chart_outlined : Icons.view_agenda_outlined),
            onPressed: () => setState(() => _cards = !_cards),
          ),
          PopupMenuButton<String>(
            onSelected: _onMenu,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'share_xlsx', child: ListTile(leading: Icon(Icons.share), title: Text('Поделиться Excel'))),
              PopupMenuItem(value: 'share_csv', child: ListTile(leading: Icon(Icons.description_outlined), title: Text('Поделиться CSV'))),
              PopupMenuItem(value: 'share_text', child: ListTile(leading: Icon(Icons.short_text), title: Text('Поделиться текстом'))),
              PopupMenuDivider(),
              PopupMenuItem(value: 'columns', child: ListTile(leading: Icon(Icons.view_column_outlined), title: Text('Колонки…'))),
              PopupMenuItem(value: 'sort', child: ListTile(leading: Icon(Icons.sort), title: Text('Сортировка…'))),
              PopupMenuItem(value: 'stats', child: ListTile(leading: Icon(Icons.functions), title: Text('Итоги по колонке…'))),
              PopupMenuDivider(),
              PopupMenuItem(value: 'tsv', child: ListTile(leading: Icon(Icons.copy), title: Text('Копировать таблицу (TSV)'))),
              PopupMenuItem(value: 'csv', child: ListTile(leading: Icon(Icons.copy), title: Text('Копировать CSV'))),
              PopupMenuItem(value: 'sql', child: ListTile(leading: Icon(Icons.code), title: Text('Копировать SQL'))),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: Row(children: [
              Expanded(child: Text(info, style: Theme.of(context).textTheme.bodySmall)),
              SizedBox(
                width: 150,
                height: 36,
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'Фильтр',
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 18),
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(vertical: 6),
                  ),
                  onChanged: (v) => setState(() => _filter = v),
                ),
              ),
            ]),
          ),
          if (r.truncated)
            Container(
              width: double.infinity,
              color: cs.tertiaryContainer,
              padding: const EdgeInsets.all(6),
              child: Text('Показаны первые ${r.rows.length} строк — добавьте LIMIT', textAlign: TextAlign.center),
            ),
          Expanded(child: body),
        ],
      ),
    );
  }

  void _onMenu(String v) {
    switch (v) {
      case 'share_xlsx':
        _share(ShareFormat.xlsx);
      case 'share_csv':
        _share(ShareFormat.csv);
      case 'share_text':
        _share(ShareFormat.text);
      case 'columns':
        _chooseColumns();
      case 'sort':
        _pickColumn('Сортировать по', _columnMenu);
      case 'stats':
        _pickColumn('Итоги по колонке', _showStats);
      case 'tsv':
        copyText(context, _currentView.toTsv(), 'Скопировано (TSV, вставляется в Excel/Sheets)');
      case 'csv':
        copyText(context, _currentView.toCsv(), 'Скопировано (CSV)');
      case 'sql':
        copyText(context, widget.sql, 'SQL скопирован');
    }
  }

  Widget _cardList(List<List<String?>> rows, List<int> cols) {
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: rows.length,
      itemBuilder: (ctx, i) {
        final row = rows[i];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: InkWell(
            onTap: () => _showRow(row),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final c in cols.take(12))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        SizedBox(
                          width: 110,
                          child: Text(r.columns[c],
                              style: Theme.of(ctx).textTheme.labelSmall,
                              overflow: TextOverflow.ellipsis),
                        ),
                        Expanded(
                          child: Text(row[c] ?? 'NULL',
                              style: monoStyle.copyWith(
                                color: row[c] == null ? Colors.grey : null,
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis),
                        ),
                      ]),
                    ),
                  if (cols.length > 12)
                    Text('… ещё ${cols.length - 12} полей',
                        style: Theme.of(ctx).textTheme.bodySmall),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _table(List<List<String?>> rows, List<int> cols, double totalWidth, ColorScheme cs) {
    const rowH = 34.0;
    Widget cell(String? v, double w, {bool header = false}) => Container(
          width: w,
          height: rowH,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            border: Border(right: BorderSide(color: cs.outlineVariant, width: 0.5)),
          ),
          child: Text(
            v ?? 'NULL',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: header
                ? const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)
                : monoStyle.copyWith(color: v == null ? Colors.grey : null),
          ),
        );

    Widget headerCell(int i) {
      final arrow = _sortCol == i ? (_sortAsc ? ' ↑' : ' ↓') : '';
      return InkWell(
        onTap: () => _columnMenu(i),
        child: cell('${r.columns[i]}$arrow', _widths[i], header: true),
      );
    }

    return Scrollbar(
      controller: _hScroll,
      child: SingleChildScrollView(
        controller: _hScroll,
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: totalWidth,
          child: Column(
            children: [
              Container(
                color: cs.surfaceContainerHighest,
                child: Row(children: [
                  cell('#', 40, header: true),
                  for (final i in cols) headerCell(i),
                ]),
              ),
              Expanded(
                child: ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemExtent: rowH,
                  itemCount: rows.length,
                  itemBuilder: (ctx, idx) {
                    final row = rows[idx];
                    return InkWell(
                      onTap: () => _showRow(row),
                      child: Container(
                        color: idx.isOdd ? cs.surfaceContainerLow : null,
                        child: Row(children: [
                          cell('${idx + 1}', 40),
                          for (final i in cols) cell(row[i], _widths[i]),
                        ]),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
