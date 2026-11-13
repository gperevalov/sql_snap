import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:mysql_client/mysql_client.dart';
import 'package:postgres/postgres.dart' as pg;

import 'models.dart';
import 'template_engine.dart';

const maxRows = 5000;
const connectTimeout = Duration(seconds: 15);
const queryTimeout = Duration(minutes: 3);

class DbException implements Exception {
  final String message;
  DbException(this.message);
  @override
  String toString() => message;
}

String? _fmt(Object? v) {
  if (v == null) return null;
  if (v is String) return v;
  if (v is DateTime) {
    final s = v.toIso8601String().replaceFirst('T', ' ');
    return s.endsWith('.000') ? s.substring(0, s.length - 4) : s;
  }
  if (v is Uint8List) {
    if (v.length > 64) return '<${v.length} bytes>';
    return '0x${v.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }
  if (v is Map || v is List) {
    try {
      return jsonEncode(v);
    } catch (_) {
      return v.toString();
    }
  }
  if (v.runtimeType.toString() == 'UndecodedBytes') {
    try {
      return (v as dynamic).asString as String;
    } catch (_) {}
  }
  return v.toString();
}

/// Executes [sql] against [c]. Throws [DbException] on any error.
Future<QueryResult> runQuery(DbConnection c, String password, String sql) async {
  if (c.readOnly && isWriteQuery(sql)) {
    throw DbException('Подключение «${c.name}» только для чтения');
  }
  final sw = Stopwatch()..start();
  try {
    switch (c.type) {
      case DbType.postgres:
        return await _runPostgres(c, password, sql, sw);
      case DbType.mysql:
        return await _runMysql(c, password, sql, sw);
      case DbType.clickhouse:
        return await _runClickhouse(c, password, sql, sw);
    }
  } on DbException {
    rethrow;
  } catch (e) {
    throw DbException(_cleanError(e));
  }
}

String _cleanError(Object e) {
  var s = e.toString();
  for (final p in ['Exception: ', 'MySQLServerException: ', 'MySQLClientException: ']) {
    if (s.startsWith(p)) s = s.substring(p.length);
  }
  return s;
}

Future<QueryResult> _runPostgres(
    DbConnection c, String password, String sql, Stopwatch sw) async {
  final conn = await pg.Connection.open(
    pg.Endpoint(
      host: c.host,
      port: c.port,
      database: c.database.isEmpty ? 'postgres' : c.database,
      username: c.user,
      password: password,
    ),
    settings: pg.ConnectionSettings(
      sslMode: c.ssl ? pg.SslMode.require : pg.SslMode.disable,
    ),
  ).timeout(connectTimeout);
  try {
    final res = await conn
        .execute(sql, queryMode: pg.QueryMode.simple)
        .timeout(queryTimeout);
    final cols = res.schema.columns
        .map((col) => col.columnName ?? '?')
        .toList();
    final rows = <List<String?>>[];
    for (final r in res) {
      if (rows.length >= maxRows) break;
      rows.add(r.map(_fmt).toList());
    }
    return QueryResult(
      columns: cols,
      rows: rows,
      affectedRows: cols.isEmpty ? res.affectedRows : null,
      elapsed: sw.elapsed,
      truncated: res.length > maxRows,
    );
  } finally {
    await conn.close();
  }
}

Future<QueryResult> _runMysql(
    DbConnection c, String password, String sql, Stopwatch sw) async {
  final conn = await MySQLConnection.createConnection(
    host: c.host,
    port: c.port,
    userName: c.user,
    password: password,
    databaseName: c.database.isEmpty ? null : c.database,
    secure: c.ssl,
  );
  await conn.connect(timeoutMs: connectTimeout.inMilliseconds);
  try {
    final res = await conn.execute(sql).timeout(queryTimeout);
    final cols = res.cols.map((col) => col.name).toList();
    final rows = <List<String?>>[];
    var total = 0;
    for (final r in res.rows) {
      total++;
      if (rows.length >= maxRows) continue;
      rows.add(List<String?>.generate(cols.length, (i) => r.colAt(i)));
    }
    return QueryResult(
      columns: cols,
      rows: rows,
      affectedRows: cols.isEmpty ? res.affectedRows.toInt() : null,
      elapsed: sw.elapsed,
      truncated: total > maxRows,
    );
  } finally {
    await conn.close();
  }
}

Future<QueryResult> _runClickhouse(
    DbConnection c, String password, String sql, Stopwatch sw) async {
  var body = sql.trim();
  while (body.endsWith(';')) {
    body = body.substring(0, body.length - 1).trimRight();
  }
  final uri = Uri(
    scheme: c.ssl ? 'https' : 'http',
    host: c.host,
    port: c.port,
    path: '/',
    queryParameters: {
      if (c.database.isNotEmpty) 'database': c.database,
      'default_format': 'JSONCompact',
      'wait_end_of_query': '1',
      'output_format_json_quote_64bit_integers': '0',
      if (c.readOnly) 'readonly': '2',
    },
  );
  final resp = await http
      .post(
        uri,
        headers: {
          'X-ClickHouse-User': c.user.isEmpty ? 'default' : c.user,
          'X-ClickHouse-Key': password,
          'Content-Type': 'text/plain; charset=utf-8',
        },
        body: utf8.encode(body),
      )
      .timeout(queryTimeout);
  final text = utf8.decode(resp.bodyBytes, allowMalformed: true);
  if (resp.statusCode != 200) {
    throw DbException(text.trim().isEmpty ? 'HTTP ${resp.statusCode}' : text.trim());
  }
  if (text.trim().isEmpty) {
    return QueryResult(columns: const [], rows: const [], elapsed: sw.elapsed, message: 'OK');
  }
  try {
    final j = jsonDecode(text);
    if (j is Map && j['meta'] is List && j['data'] is List) {
      final cols = (j['meta'] as List).map((m) => '${(m as Map)['name']}').toList();
      final data = j['data'] as List;
      final rows = data
          .take(maxRows)
          .map((r) => (r as List).map(_fmt).toList())
          .toList();
      return QueryResult(
        columns: cols,
        rows: rows,
        elapsed: sw.elapsed,
        truncated: data.length > maxRows,
      );
    }
  } catch (_) {
    // Not JSON (e.g. user specified FORMAT) — show as text below.
  }
  final lines = const LineSplitter().convert(text);
  return QueryResult(
    columns: const ['result'],
    rows: lines.take(maxRows).map((l) => <String?>[l]).toList(),
    elapsed: sw.elapsed,
    truncated: lines.length > maxRows,
  );
}
