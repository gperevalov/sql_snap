import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'sqlfile.dart';
import 'store.dart';

class GithubException implements Exception {
  final String message;
  GithubException(this.message);
  @override
  String toString() => message;
}

class RemoteFile {
  final String path;
  final String sha;
  RemoteFile(this.path, this.sha);
}

/// Syncs templates with a directory of .sql files in a GitHub repository
/// (sub-folders become template folders).
class GithubSync {
  final AppStore store;
  final String token;
  GithubSync(this.store, this.token);

  GithubSettings get s => store.github;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'sqlsnap',
      };

  String get _dir => s.dir.replaceAll(RegExp(r'^/+|/+$'), '');

  Uri _contents(String path, {bool withRef = true}) => Uri.https(
        'api.github.com',
        '/repos/${s.repo}/contents/$path',
        withRef ? {'ref': s.branch} : null,
      );

  void _check(http.Response r) {
    if (r.statusCode >= 300) {
      String msg = r.body;
      try {
        msg = (jsonDecode(r.body) as Map)['message'].toString();
      } catch (_) {}
      throw GithubException('GitHub ${r.statusCode}: $msg');
    }
  }

  /// Lists all .sql files under the configured dir (uses the git trees API).
  Future<List<RemoteFile>> listRemote() async {
    if (s.repo.isEmpty || !s.repo.contains('/')) {
      throw GithubException('Укажите репозиторий в виде owner/name');
    }
    final r = await http.get(
      Uri.https('api.github.com', '/repos/${s.repo}/git/trees/${s.branch}', {'recursive': '1'}),
      headers: _headers,
    );
    if (r.statusCode == 404 || r.statusCode == 409) {
      // Empty repo or missing branch.
      return [];
    }
    _check(r);
    final tree = (jsonDecode(r.body) as Map)['tree'] as List;
    final prefix = _dir.isEmpty ? '' : '$_dir/';
    return tree
        .map((e) => e as Map)
        .where((e) =>
            e['type'] == 'blob' &&
            (e['path'] as String).startsWith(prefix) &&
            (e['path'] as String).toLowerCase().endsWith('.sql'))
        .map((e) => RemoteFile(e['path'] as String, e['sha'] as String))
        .toList();
  }

  Future<String> _download(String path) async {
    final r = await http.get(_contents(path), headers: _headers);
    _check(r);
    final j = jsonDecode(r.body) as Map;
    final b64 = (j['content'] as String).replaceAll('\n', '');
    return utf8.decode(base64Decode(b64));
  }

  String _folderFromPath(String path) {
    final prefix = _dir.isEmpty ? '' : '$_dir/';
    final rel = path.substring(prefix.length);
    final idx = rel.lastIndexOf('/');
    return idx < 0 ? '' : rel.substring(0, idx);
  }

  String _pathFor(QueryTemplate t) {
    final parts = <String>[
      if (_dir.isNotEmpty) _dir,
      if (t.folder.isNotEmpty) ...t.folder.split('/').map(slugify),
      '${slugify(t.name)}.sql',
    ];
    return parts.join('/');
  }

  /// Repo -> phone. Templates that came from the repo and were removed there
  /// are removed locally; local-only templates are kept.
  Future<String> pull() async {
    final files = await listRemote();
    final remotePaths = files.map((f) => f.path).toSet();
    var added = 0, updated = 0, removed = 0;
    for (final f in files) {
      final text = await _download(f.path);
      final name = f.path.split('/').last.replaceAll(RegExp(r'\.sql$', caseSensitive: false), '');
      final t = sqlFileToTemplate(text, fallbackName: name);
      if (t.folder.isEmpty) t.folder = _folderFromPath(f.path);
      t.sourcePath = f.path;
      final i = store.templates.indexWhere((x) => x.sourcePath == f.path);
      final j = i >= 0
          ? i
          : store.templates.indexWhere((x) => x.sourcePath == null && x.name == t.name && x.folder == t.folder);
      if (j >= 0) {
        t.id = store.templates[j].id;
        store.templates[j] = t;
        updated++;
      } else {
        store.templates.add(t);
        added++;
      }
    }
    final before = store.templates.length;
    store.templates.removeWhere((t) => t.sourcePath != null && !remotePaths.contains(t.sourcePath));
    removed = before - store.templates.length;
    store.changed();
    return 'Из GitHub: новых $added, обновлено $updated, удалено $removed';
  }

  /// Phone -> repo. Uploads changed templates; optionally deletes remote .sql
  /// files that no longer exist on the phone.
  Future<String> push({bool deleteMissing = false}) async {
    final files = await listRemote();
    final shaByPath = {for (final f in files) f.path: f.sha};
    var uploaded = 0, same = 0, deleted = 0;
    final keep = <String>{};
    for (final t in store.templates) {
      final path = t.sourcePath ?? _pathFor(t);
      keep.add(path);
      final content = templateToSqlFile(t);
      final sha = shaByPath[path];
      if (sha != null && sha == _gitBlobSha(content)) {
        same++;
        t.sourcePath = path;
        continue;
      }
      final r = await http.put(
        _contents(path, withRef: false),
        headers: _headers,
        body: jsonEncode({
          'message': 'sqlsnap: ${sha == null ? 'add' : 'update'} ${t.name}',
          'content': base64Encode(utf8.encode(content)),
          'branch': s.branch,
          if (sha != null) 'sha': sha,
        }),
      );
      _check(r);
      t.sourcePath = path;
      uploaded++;
    }
    if (deleteMissing) {
      for (final f in files) {
        if (keep.contains(f.path)) continue;
        final req = http.Request('DELETE', _contents(f.path, withRef: false));
        req.headers.addAll(_headers);
        req.body = jsonEncode({
          'message': 'sqlsnap: delete ${f.path}',
          'sha': f.sha,
          'branch': s.branch,
        });
        final resp = await http.Response.fromStream(await req.send());
        _check(resp);
        deleted++;
      }
    }
    store.changed();
    return 'В GitHub: загружено $uploaded, без изменений $same${deleteMissing ? ', удалено $deleted' : ''}';
  }

  /// git blob SHA-1 of content, to skip unchanged files.
  String _gitBlobSha(String content) {
    final bytes = utf8.encode(content);
    final header = utf8.encode('blob ${bytes.length}\u0000');
    return _sha1([...header, ...bytes]);
  }
}

// Minimal SHA-1 (avoids an extra dependency).
String _sha1(List<int> message) {
  int rotl(int x, int n) => ((x << n) | (x >> (32 - n))) & 0xffffffff;
  final ml = message.length * 8;
  final msg = <int>[...message, 0x80];
  while (msg.length % 64 != 56) {
    msg.add(0);
  }
  for (var i = 7; i >= 0; i--) {
    msg.add((ml >> (i * 8)) & 0xff);
  }
  var h0 = 0x67452301, h1 = 0xEFCDAB89, h2 = 0x98BADCFE, h3 = 0x10325476, h4 = 0xC3D2E1F0;
  final w = List<int>.filled(80, 0);
  for (var chunk = 0; chunk < msg.length; chunk += 64) {
    for (var i = 0; i < 16; i++) {
      final j = chunk + i * 4;
      w[i] = (msg[j] << 24) | (msg[j + 1] << 16) | (msg[j + 2] << 8) | msg[j + 3];
    }
    for (var i = 16; i < 80; i++) {
      w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }
    var a = h0, b = h1, c = h2, d = h3, e = h4;
    for (var i = 0; i < 80; i++) {
      int f, k;
      if (i < 20) {
        f = (b & c) | ((~b & 0xffffffff) & d);
        k = 0x5A827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDC;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6;
      }
      final temp = (rotl(a, 5) + f + e + k + w[i]) & 0xffffffff;
      e = d;
      d = c;
      c = rotl(b, 30);
      b = a;
      a = temp;
    }
    h0 = (h0 + a) & 0xffffffff;
    h1 = (h1 + b) & 0xffffffff;
    h2 = (h2 + c) & 0xffffffff;
    h3 = (h3 + d) & 0xffffffff;
    h4 = (h4 + e) & 0xffffffff;
  }
  return [h0, h1, h2, h3, h4].map((h) => h.toRadixString(16).padLeft(8, '0')).join();
}
