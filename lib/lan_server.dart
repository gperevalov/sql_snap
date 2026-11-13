import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'db.dart';
import 'models.dart';
import 'store.dart';
import 'template_engine.dart';

/// Small HTTP server on the phone so templates and connections can be edited
/// (and queries run) from a PC browser in the same Wi‑Fi network.
class LanServer extends ChangeNotifier {
  LanServer._();
  static final LanServer instance = LanServer._();

  HttpServer? _server;
  String token = '';
  List<String> addresses = [];
  String? error;
  int requests = 0;

  bool get running => _server != null;
  AppStore get store => AppStore.instance;

  List<String> get urls =>
      addresses.map((a) => 'http://$a:${store.lanPort}/?t=$token').toList();

  Future<void> start() async {
    if (running) return;
    error = null;
    final r = Random.secure();
    const abc = 'abcdefghjkmnpqrstuvwxyz23456789';
    token = List.generate(10, (_) => abc[r.nextInt(abc.length)]).join();
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, store.lanPort, shared: true);
      _server!.listen(_handle, onError: (e) => debugPrint('lan: $e'));
      addresses = await _localAddresses();
    } catch (e) {
      error = 'Не удалось запустить сервер: $e';
      _server = null;
    }
    notifyListeners();
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    notifyListeners();
  }

  Future<List<String>> _localAddresses() async {
    final out = <String>[];
    try {
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final i in ifs) {
        for (final a in i.addresses) {
          if (!a.isLoopback) out.add(a.address);
        }
      }
    } catch (_) {}
    // Prefer typical home/office LAN ranges first.
    int rank(String a) => a.startsWith('192.168.')
        ? 0
        : a.startsWith('10.')
            ? 1
            : a.startsWith('172.')
                ? 2
                : 3;
    out.sort((a, b) => rank(a).compareTo(rank(b)));
    return out;
  }

  Future<void> _handle(HttpRequest req) async {
    requests++;
    final res = req.response;
    res.headers.set('Cache-Control', 'no-store');
    try {
      final path = req.uri.path;
      if (path == '/' || path == '/index.html') {
        if (req.uri.queryParameters['t'] != token) {
          res.statusCode = 403;
          res.headers.contentType = ContentType.html;
          res.write('<meta charset="utf-8"><h3>Откройте ссылку, показанную в приложении SQL Snap (в ней есть ключ доступа).</h3>');
          await res.close();
          return;
        }
        final html = await rootBundle.loadString('assets/web/index.html');
        res.headers.contentType = ContentType.html;
        res.write(html);
        await res.close();
        return;
      }
      if (!path.startsWith('/api/')) {
        res.statusCode = 404;
        await res.close();
        return;
      }
      if (req.headers.value('X-Token') != token) {
        await _json(res, {'error': 'Неверный ключ доступа — откройте ссылку из приложения заново'}, 401);
        return;
      }
      final body = req.method == 'GET'
          ? null
          : await utf8.decoder.bind(req).join();
      final data = (body == null || body.isEmpty) ? <String, dynamic>{} : jsonDecode(body);
      await _json(res, await _api(req.method, path.substring(5), data));
    } catch (e) {
      try {
        await _json(res, {'error': e.toString()}, 400);
      } catch (_) {}
    }
  }

  Future<void> _json(HttpResponse res, Object? data, [int status = 200]) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(data));
    await res.close();
  }

  Future<Map<String, dynamic>> _connJson(DbConnection c) async =>
      {...c.toJson(), 'hasPassword': await store.hasPassword(c.id)};

  DbConnection _resolveConn(dynamic data) {
    final id = (data['connectionId'] ?? '').toString();
    final name = (data['connection'] ?? '').toString();
    final c = (id.isNotEmpty ? store.connectionById(id) : null) ??
        (name.isNotEmpty ? store.connectionByName(name) : null);
    if (c == null) throw Exception('Подключение не найдено: ${name.isNotEmpty ? name : id}');
    return c;
  }

  Future<Object?> _api(String method, String route, dynamic data) async {
    final seg = route.split('/');
    switch ('$method ${seg.first}') {
      case 'GET state': {
        return {
          'connections': [for (final c in store.connections) await _connJson(c)],
          'templates': store.templates.map((t) => t.toJson()).toList(),
          'folders': store.folders,
          'varTypes': varTypeLabels,
        };
      }
      case 'POST templates': {
        final t = QueryTemplate.fromJson(Map<String, dynamic>.from(data as Map));
        store.upsertTemplate(t);
        return t.toJson();
      }
      case 'DELETE templates': {
        store.deleteTemplate(seg[1]);
        return {'ok': true};
      }
      case 'POST connections': {
        final c = DbConnection.fromJson(Map<String, dynamic>.from(data['connection'] as Map));
        final pwd = data['password'] as String?;
        await store.upsertConnection(c, password: (pwd == null || pwd.isEmpty) ? null : pwd);
        return await _connJson(c);
      }
      case 'DELETE connections': {
        await store.deleteConnection(seg[1]);
        return {'ok': true};
      }
      case 'POST test': {
        final c = _resolveConn(data);
        final r = await runQuery(c, await store.password(c.id), 'SELECT 1');
        return {'ok': true, 'elapsedMs': r.elapsed.inMilliseconds};
      }
      case 'POST sync-vars': {
        final sql = (data['sql'] ?? '').toString();
        final vars = ((data['vars'] as List?) ?? [])
            .map((e) => TemplateVar.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        return {'vars': syncVars(sql, vars).map((v) => v.toJson()).toList()};
      }
      case 'POST prepare': {
        final t = QueryTemplate.fromJson(Map<String, dynamic>.from(data['template'] as Map));
        return {
          'defaults': {for (final v in t.vars) v.name: resolveDefault(v)},
          'recent': {for (final v in t.vars) v.name: store.recentValues(t.id, v.name)},
          'optional': optionalVarNames(t.sql).toList(),
        };
      }
      case 'POST render': {
        final t = QueryTemplate.fromJson(Map<String, dynamic>.from(data['template'] as Map));
        final values = Map<String, dynamic>.from((data['values'] as Map?) ?? {})
            .map((k, v) => MapEntry(k, v?.toString() ?? ''));
        final c = store.connectionByName(t.connection);
        final sql = renderSql(t.sql, t.vars, values, c?.type ?? DbType.mysql);
        if (data['remember'] == true) store.rememberValues(t.id, values);
        return {'sql': sql, 'isWrite': isWriteQuery(sql), 'connectionId': c?.id};
      }
      case 'POST run': {
        final c = _resolveConn(data);
        final sql = (data['sql'] ?? '').toString();
        try {
          final r = await runQuery(c, await store.password(c.id), sql);
          return r.toJson();
        } on DbException catch (e) {
          return {'error': e.message};
        }
      }
      case 'GET export': {
        return await store.exportBundle();
      }
      case 'POST import': {
        return {'message': await store.importBundle(Map<String, dynamic>.from(data as Map))};
      }
    }
    throw Exception('Unknown API: $method $route');
  }
}
