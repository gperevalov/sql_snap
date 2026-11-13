import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// One executed query with (the beginning of) its result, viewable offline.
class RunRecord {
  final String id;
  final DateTime at;
  final String title;
  final String connectionId;
  final String connectionName;
  final String sql;
  final QueryResult result;

  RunRecord({
    String? id,
    DateTime? at,
    required this.title,
    required this.connectionId,
    required this.connectionName,
    required this.sql,
    required this.result,
  })  : id = id ?? newId(),
        at = at ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'at': at.millisecondsSinceEpoch,
        'title': title,
        'connectionId': connectionId,
        'connectionName': connectionName,
        'sql': sql,
        'result': result.toJson(),
      };

  factory RunRecord.fromJson(Map<String, dynamic> j) => RunRecord(
        id: j['id'] as String?,
        at: DateTime.fromMillisecondsSinceEpoch(int.tryParse('${j['at']}') ?? 0),
        title: (j['title'] ?? '').toString(),
        connectionId: (j['connectionId'] ?? '').toString(),
        connectionName: (j['connectionName'] ?? '').toString(),
        sql: (j['sql'] ?? '').toString(),
        result: QueryResult.fromJson(Map<String, dynamic>.from(j['result'] as Map)),
      );
}

/// Last executed queries, kept in a separate file so big results don't slow down the main store.
class RunHistory extends ChangeNotifier {
  RunHistory._();
  static final RunHistory instance = RunHistory._();

  /// How many runs to keep and how many rows of each result.
  static const maxRuns = 20;
  static const maxRowsPerRun = 500;

  List<RunRecord> runs = [];
  File? _file;
  Timer? _saveTimer;

  Future<void> load() async {
    final dir = await getApplicationSupportDirectory();
    _file = File('${dir.path}/runs.json');
    try {
      if (await _file!.exists()) {
        runs = (jsonDecode(await _file!.readAsString()) as List)
            .map((e) => RunRecord.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      }
    } catch (e) {
      debugPrint('Failed to load run history: $e');
    }
    notifyListeners();
  }

  void add(RunRecord r) {
    runs.insert(
      0,
      RunRecord(
        id: r.id,
        at: r.at,
        title: r.title,
        connectionId: r.connectionId,
        connectionName: r.connectionName,
        sql: r.sql,
        result: r.result.head(maxRowsPerRun),
      ),
    );
    if (runs.length > maxRuns) runs.removeRange(maxRuns, runs.length);
    _save();
  }

  void clear() {
    runs.clear();
    _save();
  }

  void _save() {
    notifyListeners();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () async {
      final f = _file;
      if (f == null) return;
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(runs.map((r) => r.toJson()).toList()));
      await tmp.rename(f.path);
    });
  }
}
