import 'package:flutter/material.dart';

import '../run_history.dart';
import '../store.dart';
import 'common.dart';
import 'results_screen.dart';

String _two(int v) => v.toString().padLeft(2, '0');

/// «14:05» for today, «12.11 14:05» otherwise.
String formatRunTime(DateTime t) {
  final now = DateTime.now();
  final hm = '${_two(t.hour)}:${_two(t.minute)}';
  final today = t.year == now.year && t.month == now.month && t.day == now.day;
  return today ? hm : '${_two(t.day)}.${_two(t.month)} $hm';
}

/// Last executed queries with their results — open them without network.
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final history = RunHistory.instance;
    return ListenableBuilder(
      listenable: history,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('История запусков'),
          actions: [
            if (history.runs.isNotEmpty)
              IconButton(
                tooltip: 'Очистить',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: () async {
                  if (await confirm(context, 'Очистить историю?', 'Сохранённые результаты будут удалены.',
                      ok: 'Очистить', danger: true)) {
                    history.clear();
                  }
                },
              ),
          ],
        ),
        body: history.runs.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'Здесь появятся последние ${RunHistory.maxRuns} выполненных запросов.\n'
                    'Их результаты можно открыть даже без интернета.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : ListView.separated(
                itemCount: history.runs.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) => _tile(context, history.runs[i]),
              ),
      ),
    );
  }

  Widget _tile(BuildContext context, RunRecord run) {
    final r = run.result;
    final size = r.columns.isEmpty
        ? (r.affectedRows != null ? 'затронуто ${r.affectedRows}' : (r.message ?? 'OK'))
        : '${r.rows.length}${r.truncated ? '+' : ''} строк';
    return ListTile(
      title: Text(run.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${formatRunTime(run.at)} • ${run.connectionName} • $size\n${run.sql.replaceAll(RegExp(r'\s+'), ' ')}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: true,
      trailing: IconButton(
        tooltip: 'Копировать SQL',
        icon: const Icon(Icons.copy, size: 18),
        onPressed: () => copyText(context, run.sql, 'SQL скопирован'),
      ),
      onTap: r.columns.isEmpty
          ? null
          : () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ResultsScreen(
                    result: r,
                    title: run.title,
                    sql: run.sql,
                    connection: AppStore.instance.connectionById(run.connectionId),
                    note: 'из истории, ${formatRunTime(run.at)}',
                  ),
                ),
              ),
    );
  }
}
