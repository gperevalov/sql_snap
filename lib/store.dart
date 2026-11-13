import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

class GithubSettings {
  String repo; // owner/name
  String branch;
  String dir;

  GithubSettings({this.repo = '', this.branch = 'main', this.dir = 'templates'});

  Map<String, dynamic> toJson() => {'repo': repo, 'branch': branch, 'dir': dir};

  factory GithubSettings.fromJson(Map<String, dynamic>? j) => GithubSettings(
        repo: (j?['repo'] ?? '').toString(),
        branch: ((j?['branch'] ?? '').toString().isEmpty ? 'main' : j!['branch']).toString(),
        dir: (j?['dir'] ?? 'templates').toString(),
      );
}

class AppStore extends ChangeNotifier {
  AppStore._();
  static final AppStore instance = AppStore._();

  final _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  List<DbConnection> connections = [];
  List<QueryTemplate> templates = [];
  GithubSettings github = GithubSettings();
  int lanPort = 8787;

  /// templateId -> varName -> last values (most recent first)
  Map<String, Map<String, List<String>>> history = {};

  File? _file;
  Timer? _saveTimer;

  Future<void> load() async {
    final dir = await getApplicationSupportDirectory();
    _file = File('${dir.path}/sqlsnap.json');
    if (await _file!.exists()) {
      try {
        final j = jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
        connections = ((j['connections'] as List?) ?? [])
            .map((e) => DbConnection.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        templates = ((j['templates'] as List?) ?? [])
            .map((e) => QueryTemplate.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        github = GithubSettings.fromJson(
            j['github'] == null ? null : Map<String, dynamic>.from(j['github'] as Map));
        lanPort = int.tryParse('${j['lanPort']}') ?? 8787;
        final h = (j['history'] as Map?) ?? {};
        history = h.map<String, Map<String, List<String>>>((k, v) => MapEntry(
              k.toString(),
              (v as Map).map<String, List<String>>((vk, vv) => MapEntry(
                    vk.toString(),
                    (vv as List).map((e) => e.toString()).toList(),
                  )),
            ));
      } catch (e) {
        debugPrint('Failed to load data: $e');
      }
    }
    _sortTemplates();
    notifyListeners();
  }

  Map<String, dynamic> _toJson() => {
        'connections': connections.map((c) => c.toJson()).toList(),
        'templates': templates.map((t) => t.toJson()).toList(),
        'github': github.toJson(),
        'lanPort': lanPort,
        'history': history,
      };

  void save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), _writeNow);
  }

  Future<void> _writeNow() async {
    final f = _file;
    if (f == null) return;
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent(' ').convert(_toJson()));
    await tmp.rename(f.path);
  }

  void changed() {
    _sortTemplates();
    save();
    notifyListeners();
  }

  void _sortTemplates() {
    templates.sort((a, b) {
      final f = a.folder.toLowerCase().compareTo(b.folder.toLowerCase());
      if (f != 0) return f;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  // ---------- connections ----------

  DbConnection? connectionById(String id) {
    for (final c in connections) {
      if (c.id == id) return c;
    }
    return null;
  }

  DbConnection? connectionByName(String name) {
    for (final c in connections) {
      if (c.name == name) return c;
    }
    final lower = name.toLowerCase();
    for (final c in connections) {
      if (c.name.toLowerCase() == lower) return c;
    }
    return null;
  }

  Future<String> password(String connId) async =>
      (await _secure.read(key: 'pwd_$connId')) ?? '';

  Future<bool> hasPassword(String connId) async =>
      ((await _secure.read(key: 'pwd_$connId')) ?? '').isNotEmpty;

  /// [password] null = keep existing.
  Future<void> upsertConnection(DbConnection c, {String? password}) async {
    final i = connections.indexWhere((x) => x.id == c.id);
    if (i >= 0) {
      final oldName = connections[i].name;
      connections[i] = c;
      if (oldName != c.name) {
        for (final t in templates) {
          if (t.connection == oldName) t.connection = c.name;
        }
      }
    } else {
      connections.add(c);
    }
    if (password != null) {
      await _secure.write(key: 'pwd_${c.id}', value: password);
    }
    changed();
  }

  Future<void> deleteConnection(String id) async {
    connections.removeWhere((c) => c.id == id);
    await _secure.delete(key: 'pwd_$id');
    changed();
  }

  // ---------- templates ----------

  QueryTemplate? templateById(String id) {
    for (final t in templates) {
      if (t.id == id) return t;
    }
    return null;
  }

  void upsertTemplate(QueryTemplate t) {
    t.updatedAt = DateTime.now().millisecondsSinceEpoch;
    final i = templates.indexWhere((x) => x.id == t.id);
    if (i >= 0) {
      templates[i] = t;
    } else {
      templates.add(t);
    }
    changed();
  }

  void deleteTemplate(String id) {
    templates.removeWhere((t) => t.id == id);
    history.remove(id);
    changed();
  }

  List<String> get folders {
    final s = templates.map((t) => t.folder).where((f) => f.isNotEmpty).toSet().toList();
    s.sort();
    return s;
  }

  // ---------- history of entered values ----------

  List<String> recentValues(String templateId, String varName) =>
      history[templateId]?[varName] ?? const [];

  void rememberValues(String templateId, Map<String, String> values) {
    final h = history.putIfAbsent(templateId, () => {});
    values.forEach((k, v) {
      if (v.trim().isEmpty) return;
      final list = h.putIfAbsent(k, () => []);
      list.remove(v);
      list.insert(0, v);
      if (list.length > 8) list.removeRange(8, list.length);
    });
    save();
  }

  // ---------- github token ----------

  Future<String> githubToken() async => (await _secure.read(key: 'gh_token')) ?? '';
  Future<void> setGithubToken(String t) => _secure.write(key: 'gh_token', value: t);

  // ---------- export / import ----------

  Future<Map<String, dynamic>> exportBundle({bool withPasswords = false}) async {
    final conns = <Map<String, dynamic>>[];
    for (final c in connections) {
      final j = c.toJson();
      if (withPasswords) j['password'] = await password(c.id);
      conns.add(j);
    }
    return {
      'app': 'sqlsnap',
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'connections': conns,
      'templates': templates.map((t) => t.toJson()).toList(),
    };
  }

  /// Merges a bundle. Templates are matched by id, then by folder+name;
  /// connections by name. Returns a human-readable summary.
  Future<String> importBundle(Map<String, dynamic> j) async {
    var tAdded = 0, tUpdated = 0, cAdded = 0, cUpdated = 0;
    for (final e in (j['connections'] as List?) ?? const []) {
      final m = Map<String, dynamic>.from(e as Map);
      final incoming = DbConnection.fromJson(m);
      final pwd = m['password'] as String?;
      final existing = connectionByName(incoming.name) ?? connectionById(incoming.id);
      if (existing != null) {
        incoming.id = existing.id;
        cUpdated++;
      } else {
        cAdded++;
      }
      await upsertConnection(incoming, password: (pwd != null && pwd.isNotEmpty) ? pwd : null);
    }
    for (final e in (j['templates'] as List?) ?? const []) {
      final t = QueryTemplate.fromJson(Map<String, dynamic>.from(e as Map));
      var i = templates.indexWhere((x) => x.id == t.id);
      if (i < 0) {
        i = templates.indexWhere((x) => x.folder == t.folder && x.name == t.name);
      }
      if (i >= 0) {
        t.id = templates[i].id;
        templates[i] = t;
        tUpdated++;
      } else {
        templates.add(t);
        tAdded++;
      }
    }
    changed();
    return 'Шаблоны: +$tAdded, обновлено $tUpdated. Подключения: +$cAdded, обновлено $cUpdated.';
  }
}
