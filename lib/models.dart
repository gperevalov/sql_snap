import 'dart:math';

String newId() {
  final r = Random();
  final t = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final s = List.generate(6, (_) => r.nextInt(36).toRadixString(36)).join();
  return '$t$s';
}

enum DbType { mysql, postgres, clickhouse }

DbType dbTypeFromString(String? s) {
  switch (s) {
    case 'postgres':
    case 'postgresql':
    case 'pg':
      return DbType.postgres;
    case 'clickhouse':
    case 'ch':
      return DbType.clickhouse;
    default:
      return DbType.mysql;
  }
}

String dbTypeLabel(DbType t) {
  switch (t) {
    case DbType.mysql:
      return 'MySQL';
    case DbType.postgres:
      return 'PostgreSQL';
    case DbType.clickhouse:
      return 'ClickHouse';
  }
}

int defaultPort(DbType t, {bool ssl = false}) {
  switch (t) {
    case DbType.mysql:
      return 3306;
    case DbType.postgres:
      return 5432;
    case DbType.clickhouse:
      return ssl ? 8443 : 8123;
  }
}

class DbConnection {
  String id;
  String name;
  DbType type;
  String host;
  int port;
  String database;
  String user;
  bool ssl;
  bool readOnly;

  DbConnection({
    String? id,
    this.name = '',
    this.type = DbType.mysql,
    this.host = '',
    int? port,
    this.database = '',
    this.user = '',
    this.ssl = false,
    this.readOnly = false,
  })  : id = id ?? newId(),
        port = port ?? defaultPort(type);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'host': host,
        'port': port,
        'database': database,
        'user': user,
        'ssl': ssl,
        'readOnly': readOnly,
      };

  factory DbConnection.fromJson(Map<String, dynamic> j) {
    final type = dbTypeFromString(j['type'] as String?);
    return DbConnection(
      id: (j['id'] as String?) ?? newId(),
      name: (j['name'] ?? '').toString(),
      type: type,
      host: (j['host'] ?? '').toString(),
      port: int.tryParse('${j['port']}') ?? defaultPort(type),
      database: (j['database'] ?? '').toString(),
      user: (j['user'] ?? '').toString(),
      ssl: j['ssl'] == true,
      readOnly: j['readOnly'] == true,
    );
  }

  DbConnection copy() => DbConnection.fromJson(toJson());
}

/// Variable types for templates.
const varTypes = <String>[
  'text',
  'number',
  'date',
  'datetime',
  'bool',
  'select',
  'list',
  'raw',
];

const varTypeLabels = <String, String>{
  'text': 'Текст',
  'number': 'Число',
  'date': 'Дата',
  'datetime': 'Дата и время',
  'bool': 'Да/Нет',
  'select': 'Выбор из списка',
  'list': 'Список (для IN)',
  'raw': 'Как есть (без кавычек)',
};

class TemplateVar {
  String name;
  String label;
  String type;
  String defaultValue;
  List<String> options;
  bool required;

  /// For select/list: 'text' (quoted) or 'number' (unquoted).
  String itemType;

  TemplateVar({
    required this.name,
    this.label = '',
    this.type = 'text',
    this.defaultValue = '',
    List<String>? options,
    this.required = false,
    this.itemType = 'text',
  }) : options = options ?? [];

  String get title => label.isNotEmpty ? label : name;

  Map<String, dynamic> toJson() => {
        'name': name,
        'label': label,
        'type': type,
        'default': defaultValue,
        'options': options,
        'required': required,
        'itemType': itemType,
      };

  factory TemplateVar.fromJson(Map<String, dynamic> j) => TemplateVar(
        name: (j['name'] ?? '').toString(),
        label: (j['label'] ?? '').toString(),
        type: varTypes.contains(j['type']) ? j['type'] as String : 'text',
        defaultValue: (j['default'] ?? '').toString(),
        options: ((j['options'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        required: j['required'] == true,
        itemType: j['itemType'] == 'number' ? 'number' : 'text',
      );
}

class QueryTemplate {
  String id;
  String name;
  String folder;
  String connection; // connection *name*
  String description;
  String sql;
  List<TemplateVar> vars;
  String? sourcePath; // path in GitHub repo, if synced
  int updatedAt;

  QueryTemplate({
    String? id,
    this.name = '',
    this.folder = '',
    this.connection = '',
    this.description = '',
    this.sql = '',
    List<TemplateVar>? vars,
    this.sourcePath,
    int? updatedAt,
  })  : id = id ?? newId(),
        vars = vars ?? [],
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'folder': folder,
        'connection': connection,
        'description': description,
        'sql': sql,
        'vars': vars.map((v) => v.toJson()).toList(),
        if (sourcePath != null) 'sourcePath': sourcePath,
        'updatedAt': updatedAt,
      };

  factory QueryTemplate.fromJson(Map<String, dynamic> j) => QueryTemplate(
        id: (j['id'] as String?) ?? newId(),
        name: (j['name'] ?? '').toString(),
        folder: (j['folder'] ?? '').toString(),
        connection: (j['connection'] ?? '').toString(),
        description: (j['description'] ?? '').toString(),
        sql: (j['sql'] ?? '').toString(),
        vars: ((j['vars'] as List?) ?? const [])
            .map((e) => TemplateVar.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        sourcePath: j['sourcePath'] as String?,
        updatedAt: int.tryParse('${j['updatedAt']}'),
      );

  QueryTemplate copy() => QueryTemplate.fromJson(toJson());
}

class QueryResult {
  final List<String> columns;
  final List<List<String?>> rows;
  final int? affectedRows;
  final Duration elapsed;
  final String? message;
  final bool truncated;

  QueryResult({
    required this.columns,
    required this.rows,
    this.affectedRows,
    required this.elapsed,
    this.message,
    this.truncated = false,
  });

  Map<String, dynamic> toJson() => {
        'columns': columns,
        'rows': rows,
        'affectedRows': affectedRows,
        'elapsedMs': elapsed.inMilliseconds,
        'message': message,
        'truncated': truncated,
      };

  String toTsv() {
    String esc(String? v) =>
        (v ?? 'NULL').replaceAll('\t', ' ').replaceAll('\n', ' ');
    final b = StringBuffer(columns.map(esc).join('\t'));
    for (final r in rows) {
      b.write('\n');
      b.write(r.map(esc).join('\t'));
    }
    return b.toString();
  }

  String toCsv() {
    String esc(String? v) {
      if (v == null) return '';
      if (v.contains(',') || v.contains('"') || v.contains('\n')) {
        return '"${v.replaceAll('"', '""')}"';
      }
      return v;
    }

    final b = StringBuffer(columns.map(esc).join(','));
    for (final r in rows) {
      b.write('\n');
      b.write(r.map(esc).join(','));
    }
    return b.toString();
  }
}
