import 'dart:math';

import 'package:flutter/material.dart';

import '../models.dart';
import 'common.dart';

class ResultsScreen extends StatefulWidget {
  final QueryResult result;
  final String title;
  final String sql;

  const ResultsScreen({super.key, required this.result, required this.title, required this.sql});

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  final _hScroll = ScrollController();
  String _filter = '';
  bool _cards = false;
  late List<double> _widths;

  QueryResult get r => widget.result;

  @override
  void initState() {
    super.initState();
    _widths = List.generate(r.columns.length, (i) {
      var len = r.columns[i].length;
      for (final row in r.rows.take(200)) {
        final v = row[i];
        len = max(len, v == null ? 4 : min(v.length, 60));
      }
      return (len * 8.0 + 24).clamp(56.0, 360.0).toDouble();
    });
    _cards = r.columns.length > 6 && r.rows.length <= 50;
  }

  List<List<String?>> get _rows {
    if (_filter.isEmpty) return r.rows;
    final f = _filter.toLowerCase();
    return r.rows
        .where((row) => row.any((v) => v != null && v.toLowerCase().contains(f)))
        .toList();
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

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final cs = Theme.of(context).colorScheme;
    final totalWidth = _widths.fold<double>(0, (a, b) => a + b) + 40;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: _cards ? 'Таблица' : 'Карточки',
            icon: Icon(_cards ? Icons.table_chart_outlined : Icons.view_agenda_outlined),
            onPressed: () => setState(() => _cards = !_cards),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'tsv':
                  copyText(context, r.toTsv(), 'Скопировано (TSV, вставляется в Excel/Sheets)');
                  break;
                case 'csv':
                  copyText(context, r.toCsv(), 'Скопировано (CSV)');
                  break;
                case 'sql':
                  copyText(context, widget.sql, 'SQL скопирован');
                  break;
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'tsv', child: Text('Копировать как таблицу (TSV)')),
              PopupMenuItem(value: 'csv', child: Text('Копировать как CSV')),
              PopupMenuItem(value: 'sql', child: Text('Копировать SQL')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: Row(children: [
              Expanded(
                child: Text(
                  '${r.rows.length}${r.truncated ? '+' : ''} строк • ${r.elapsed.inMilliseconds} мс'
                  '${_filter.isNotEmpty ? ' • найдено ${rows.length}' : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              SizedBox(
                width: 160,
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
              child: const Text('Показаны первые 5000 строк — добавьте LIMIT', textAlign: TextAlign.center),
            ),
          Expanded(child: _cards ? _cardList(rows) : _table(rows, totalWidth, cs)),
        ],
      ),
    );
  }

  Widget _cardList(List<List<String?>> rows) {
    return ListView.builder(
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
                  for (var c = 0; c < r.columns.length && c < 12; c++)
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
                  if (r.columns.length > 12)
                    Text('… ещё ${r.columns.length - 12} полей',
                        style: Theme.of(ctx).textTheme.bodySmall),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _table(List<List<String?>> rows, double totalWidth, ColorScheme cs) {
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
                  for (var i = 0; i < r.columns.length; i++) cell(r.columns[i], _widths[i], header: true),
                ]),
              ),
              Expanded(
                child: ListView.builder(
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
                          for (var i = 0; i < r.columns.length; i++) cell(row[i], _widths[i]),
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
