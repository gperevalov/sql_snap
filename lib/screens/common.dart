import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../db.dart';
import '../models.dart';
import '../store.dart';
import '../template_engine.dart';
import 'results_screen.dart';

void toast(BuildContext context, String msg, {bool error = false}) {
  final cs = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? cs.error : null,
      behavior: SnackBarBehavior.floating,
    ));
}

Future<void> copyText(BuildContext context, String text, [String what = 'Скопировано']) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) toast(context, what);
}

Future<bool> confirm(BuildContext context, String title, String body,
    {String ok = 'Да', bool danger = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: Text(body)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error)
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r ?? false;
}

const monoStyle = TextStyle(fontFamily: 'monospace', fontSize: 13);

Color dbColor(DbType t) {
  switch (t) {
    case DbType.mysql:
      return const Color(0xFF00758F);
    case DbType.postgres:
      return const Color(0xFF336791);
    case DbType.clickhouse:
      return const Color(0xFFE0A100);
  }
}

Widget dbBadge(DbType t) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: dbColor(t).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        t == DbType.mysql ? 'MY' : t == DbType.postgres ? 'PG' : 'CH',
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: dbColor(t)),
      ),
    );

/// Shared flow: confirm write queries, run with a progress dialog, show results.
Future<void> executeAndShow(
  BuildContext context,
  DbConnection conn,
  String sql, {
  String title = 'Результат',
}) async {
  if (sql.trim().isEmpty) return;
  if (isWriteQuery(sql)) {
    final ok = await confirm(
      context,
      'Изменяющий запрос',
      'Запрос изменит данные в «${conn.name}». Выполнить?\n\n$sql',
      ok: 'Выполнить',
      danger: true,
    );
    if (!ok || !context.mounted) return;
  }
  final nav = Navigator.of(context);
  var cancelled = false;
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 20),
          Expanded(child: Text('Выполняю в «${conn.name}»…')),
        ]),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              Navigator.pop(ctx);
            },
            child: const Text('Скрыть'),
          ),
        ],
      ),
    ),
  );
  QueryResult? result;
  String? error;
  try {
    final pwd = await AppStore.instance.password(conn.id);
    result = await runQuery(conn, pwd, sql);
  } catch (e) {
    error = e.toString();
  }
  if (!cancelled && nav.canPop()) nav.pop();
  if (!context.mounted) return;
  if (error != null) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ошибка'),
        content: SingleChildScrollView(child: SelectableText(error!, style: monoStyle)),
        actions: [
          TextButton(onPressed: () => copyText(ctx, error!), child: const Text('Копировать')),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
    return;
  }
  final r = result!;
  if (r.columns.isEmpty) {
    toast(context,
        '${r.message ?? 'Готово'}${r.affectedRows != null ? ': затронуто строк ${r.affectedRows}' : ''} • ${r.elapsed.inMilliseconds} мс');
    return;
  }
  nav.push(MaterialPageRoute(
    builder: (_) => ResultsScreen(result: r, title: title, sql: sql),
  ));
}
