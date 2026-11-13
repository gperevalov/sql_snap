import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../db.dart';
import '../models.dart';
import '../run_history.dart';
import '../store.dart';
import '../template_engine.dart';
import '../template_shortcuts.dart';
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

/// Asks the launcher to add a home-screen shortcut for [t] and tells the user how it went.
Future<void> pinTemplateShortcut(BuildContext context, QueryTemplate t) async {
  final ok = await TemplateShortcuts.pin(t);
  if (!context.mounted) return;
  toast(
    context,
    ok ? 'Подтвердите добавление ярлыка «${t.name}»' : 'Лаунчер телефона не поддерживает ярлыки',
    error: !ok,
  );
}

/// Shows a copyable error dialog.
void showErrorDialog(BuildContext context, String error) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Ошибка'),
      content: SingleChildScrollView(child: SelectableText(error, style: monoStyle)),
      actions: [
        TextButton(onPressed: () => copyText(ctx, error), child: const Text('Копировать')),
        FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
      ],
    ),
  );
}

/// Runs [sql] behind a progress dialog with a «Cancel» button.
/// Shows errors itself; returns null on error or cancel.
Future<QueryResult?> runWithProgress(BuildContext context, DbConnection conn, String sql) async {
  final nav = Navigator.of(context);
  final cancel = CancelToken();
  var dialogOpen = true;
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
              cancel.cancel();
              Navigator.pop(ctx);
            },
            child: const Text('Отменить'),
          ),
        ],
      ),
    ),
  ).whenComplete(() => dialogOpen = false);

  QueryResult? result;
  String? error;
  try {
    final pwd = await AppStore.instance.password(conn.id);
    result = await runQuery(conn, pwd, sql, cancel: cancel);
  } on QueryCancelledException {
    // handled below
  } catch (e) {
    error = e.toString();
  }
  if (dialogOpen && nav.canPop()) nav.pop();
  if (!context.mounted) return null;
  if (cancel.isCancelled) {
    toast(context, 'Запрос отменён');
    return null;
  }
  if (error != null) {
    showErrorDialog(context, error);
    return null;
  }
  return result;
}

/// Saves a successful run to the offline history.
void rememberRun(DbConnection conn, String sql, String title, QueryResult r) {
  RunHistory.instance.add(RunRecord(
    title: title,
    connectionId: conn.id,
    connectionName: conn.name,
    sql: sql,
    result: r,
  ));
}

/// Shared flow: confirm write queries, run with a progress dialog, remember, show results.
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
  final r = await runWithProgress(context, conn, sql);
  if (r == null || !context.mounted) return;
  rememberRun(conn, sql, title, r);
  if (r.columns.isEmpty) {
    toast(context,
        '${r.message ?? 'Готово'}${r.affectedRows != null ? ': затронуто строк ${r.affectedRows}' : ''} • ${r.elapsed.inMilliseconds} мс');
    return;
  }
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => ResultsScreen(result: r, title: title, sql: sql, connection: conn),
  ));
}
