import 'models.dart';

final _varRe = RegExp(r'\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}');
final _optRe = RegExp(r'\[\[(.*?)\]\]', dotAll: true);

/// Variable names in order of first appearance.
List<String> detectVars(String sql) {
  final seen = <String>{};
  final out = <String>[];
  for (final m in _varRe.allMatches(sql)) {
    final n = m.group(1)!;
    if (seen.add(n)) out.add(n);
  }
  return out;
}

/// Names of variables that appear only inside [[ optional ]] blocks.
Set<String> optionalVarNames(String sql) {
  final inside = <String>{};
  for (final m in _optRe.allMatches(sql)) {
    inside.addAll(detectVars(m.group(1)!));
  }
  final outside = detectVars(sql.replaceAll(_optRe, ''));
  return inside.difference(outside.toSet());
}

/// Keeps [existing] variable settings, adds new ones from SQL, drops removed ones.
List<TemplateVar> syncVars(String sql, List<TemplateVar> existing) {
  final byName = {for (final v in existing) v.name: v};
  return detectVars(sql).map((n) => byName[n] ?? _guessVar(n)).toList();
}

TemplateVar _guessVar(String name) {
  final n = name.toLowerCase();
  var type = 'text';
  if (n.endsWith('_id') || n == 'id' || n == 'limit' || n.endsWith('_count')) {
    type = 'number';
  } else if (n.endsWith('_ids') || n.endsWith('_list')) {
    type = 'list';
  } else if (n.contains('date') || n == 'from' || n == 'to' || n.endsWith('_day')) {
    type = 'date';
  } else if (n.endsWith('_at') || n.contains('time')) {
    type = 'datetime';
  }
  return TemplateVar(
    name: name,
    type: type,
    itemType: type == 'list' && n.endsWith('_ids') ? 'number' : 'text',
  );
}

String _two(int v) => v.toString().padLeft(2, '0');
String fmtDate(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
String fmtDateTime(DateTime d) =>
    '${fmtDate(d)} ${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';

/// Supports dynamic defaults: today, yesterday, tomorrow, today-7, today+1,
/// month_start, prev_month_start, year_start, now, now-2h, now-30m.
String resolveDefault(TemplateVar v) {
  final d = v.defaultValue.trim();
  if (d.isEmpty) return '';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  DateTime? dt;
  bool hasTime = false;
  final lower = d.toLowerCase();
  final rel = RegExp(r'^(today|now)\s*([+-])\s*(\d+)\s*([dhm]?)$').firstMatch(lower);
  if (lower == 'today') {
    dt = today;
  } else if (lower == 'yesterday') {
    dt = today.subtract(const Duration(days: 1));
  } else if (lower == 'tomorrow') {
    dt = today.add(const Duration(days: 1));
  } else if (lower == 'now') {
    dt = now;
    hasTime = true;
  } else if (lower == 'month_start') {
    dt = DateTime(now.year, now.month, 1);
  } else if (lower == 'prev_month_start') {
    dt = DateTime(now.year, now.month - 1, 1);
  } else if (lower == 'year_start') {
    dt = DateTime(now.year, 1, 1);
  } else if (rel != null) {
    final base = rel.group(1) == 'now' ? now : today;
    hasTime = rel.group(1) == 'now';
    final n = int.parse(rel.group(3)!) * (rel.group(2) == '-' ? -1 : 1);
    final unit = rel.group(4)!.isEmpty ? (hasTime ? 'h' : 'd') : rel.group(4)!;
    final dur = unit == 'd'
        ? Duration(days: n)
        : unit == 'h'
            ? Duration(hours: n)
            : Duration(minutes: n);
    dt = base.add(dur);
  }
  if (dt == null) return d;
  if (v.type == 'date') return fmtDate(dt);
  if (v.type == 'datetime') return fmtDateTime(dt);
  return hasTime ? fmtDateTime(dt) : fmtDate(dt);
}

class RenderException implements Exception {
  final String message;
  RenderException(this.message);
  @override
  String toString() => message;
}

String quoteString(String v, DbType dialect) {
  if (dialect == DbType.postgres) {
    return "'${v.replaceAll("'", "''")}'";
  }
  return "'${v.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";
}

final _numRe = RegExp(r'^-?\d+(\.\d+)?([eE][-+]?\d+)?$');
final _dateRe = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final _dtRe = RegExp(r'^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(:\d{2})?$');

String _number(String raw, String title) {
  final v = raw.trim().replaceAll(' ', '').replaceAll(',', '.');
  if (!_numRe.hasMatch(v)) {
    throw RenderException('«$title»: «$raw» — не число');
  }
  return v;
}

String literalFor(TemplateVar v, String raw, DbType dialect) {
  final title = v.title;
  switch (v.type) {
    case 'number':
      return _number(raw, title);
    case 'date':
      final s = raw.trim();
      if (!_dateRe.hasMatch(s)) {
        throw RenderException('«$title»: ожидается дата ГГГГ-ММ-ДД');
      }
      return quoteString(s, dialect);
    case 'datetime':
      var s = raw.trim().replaceFirst('T', ' ');
      if (!_dtRe.hasMatch(s)) {
        throw RenderException('«$title»: ожидается ГГГГ-ММ-ДД ЧЧ:ММ:СС');
      }
      if (s.length == 16) s = '$s:00';
      return quoteString(s, dialect);
    case 'bool':
      final s = raw.trim().toLowerCase();
      final t = ['1', 'true', 'yes', 'да', 'y', 'on'].contains(s);
      if (dialect == DbType.mysql) return t ? '1' : '0';
      return t ? 'TRUE' : 'FALSE';
    case 'select':
      return v.itemType == 'number' ? _number(raw, title) : quoteString(raw, dialect);
    case 'list':
      final splitter =
          v.itemType == 'number' ? RegExp(r'[,;\s]+') : RegExp(r'[,;\n]+');
      final items = raw
          .split(splitter)
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (items.isEmpty) {
        throw RenderException('«$title»: пустой список');
      }
      return items
          .map((e) => v.itemType == 'number'
              ? _number(e, title)
              : quoteString(e, dialect))
          .join(', ');
    case 'raw':
      return raw;
    case 'text':
    default:
      return quoteString(raw, dialect);
  }
}

/// Renders the final SQL. [values] are raw user inputs keyed by var name.
String renderSql(
  String sql,
  List<TemplateVar> vars,
  Map<String, String> values,
  DbType dialect,
) {
  final byName = {for (final v in vars) v.name: v};
  bool isEmpty(String n) => (values[n] ?? '').trim().isEmpty && byName[n]?.type != 'bool';

  // 1. Optional blocks: drop the whole block if any variable inside is empty.
  var out = sql.replaceAllMapped(_optRe, (m) {
    final inner = m.group(1)!;
    final names = detectVars(inner);
    if (names.any(isEmpty)) return '';
    return inner;
  });

  // 2. Substitute variables.
  out = out.replaceAllMapped(_varRe, (m) {
    final n = m.group(1)!;
    final v = byName[n] ?? TemplateVar(name: n);
    final raw = values[n] ?? '';
    if (raw.trim().isEmpty && v.type != 'bool') {
      if (v.required || v.type != 'text') {
        throw RenderException('Заполните «${v.title}»');
      }
    }
    return literalFor(v, raw, dialect);
  });
  return out;
}

String stripSqlComments(String sql) => sql
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), ' ')
    .replaceAll(RegExp(r'--[^\n]*'), ' ');

const _readKeywords = {
  'select',
  'with',
  'show',
  'describe',
  'desc',
  'explain',
  'values',
  'table',
  'exists',
  'use',
  'set',
  '(',
};

/// True if the statement is (probably) modifying data or schema.
bool isWriteQuery(String sql) {
  final s = stripSqlComments(sql).trimLeft().toLowerCase();
  if (s.isEmpty) return false;
  final m = RegExp(r'^[a-z_]+|^\(').firstMatch(s);
  final first = m?.group(0) ?? '';
  return !_readKeywords.contains(first);
}
