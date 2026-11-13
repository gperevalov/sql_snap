// Text format for templates stored as .sql files (e.g. in a git repo):
//
// -- name: Заказы клиента
// -- folder: Orders
// -- connection: prod-pg
// -- description: Последние заказы по клиенту
// -- var: client_id | type=number | label=ID клиента | required
// -- var: status | type=select | options=new,paid,shipped | default=new
// -- var: from | type=date | default=today-7
// SELECT * FROM orders
// WHERE client_id = {{client_id}}
//   [[ AND status = {{status}} ]]
//   AND created_at >= {{from}}

import 'models.dart';
import 'template_engine.dart';

String templateToSqlFile(QueryTemplate t) {
  final b = StringBuffer();
  String clean(String s) => s.replaceAll('\n', ' ').replaceAll('|', '/').trim();
  b.writeln('-- name: ${clean(t.name)}');
  if (t.folder.isNotEmpty) b.writeln('-- folder: ${clean(t.folder)}');
  if (t.connection.isNotEmpty) b.writeln('-- connection: ${clean(t.connection)}');
  if (t.description.isNotEmpty) b.writeln('-- description: ${clean(t.description)}');
  for (final v in t.vars) {
    final parts = <String>[v.name, 'type=${v.type}'];
    if (v.label.isNotEmpty) parts.add('label=${clean(v.label)}');
    if (v.defaultValue.isNotEmpty) parts.add('default=${clean(v.defaultValue)}');
    if (v.options.isNotEmpty) {
      parts.add('options=${v.options.map((o) => clean(o).replaceAll(',', ';')).join(',')}');
    }
    if ((v.type == 'select' || v.type == 'list') && v.itemType == 'number') {
      parts.add('item=number');
    }
    if (v.required) parts.add('required');
    b.writeln('-- var: ${parts.join(' | ')}');
  }
  b.write(t.sql.trimRight());
  b.write('\n');
  return b.toString();
}

QueryTemplate sqlFileToTemplate(String text, {String? fallbackName}) {
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  final header = RegExp(r'^--\s*(name|folder|connection|description|var)\s*:\s*(.*)$');
  final t = QueryTemplate(name: fallbackName ?? '');
  var i = 0;
  for (; i < lines.length; i++) {
    final m = header.firstMatch(lines[i].trim());
    if (m == null) {
      if (lines[i].trim().isEmpty) continue;
      break;
    }
    final key = m.group(1)!;
    final val = m.group(2)!.trim();
    switch (key) {
      case 'name':
        t.name = val;
        break;
      case 'folder':
        t.folder = val;
        break;
      case 'connection':
        t.connection = val;
        break;
      case 'description':
        t.description = val;
        break;
      case 'var':
        final parts = val.split('|').map((p) => p.trim()).toList();
        if (parts.isEmpty || parts.first.isEmpty) break;
        final v = TemplateVar(name: parts.first);
        for (final p in parts.skip(1)) {
          final eq = p.indexOf('=');
          final k = (eq < 0 ? p : p.substring(0, eq)).trim().toLowerCase();
          final pv = eq < 0 ? '' : p.substring(eq + 1).trim();
          switch (k) {
            case 'type':
              if (varTypes.contains(pv)) v.type = pv;
              break;
            case 'label':
              v.label = pv;
              break;
            case 'default':
              v.defaultValue = pv;
              break;
            case 'options':
              v.options = pv.split(',').map((o) => o.trim()).where((o) => o.isNotEmpty).toList();
              break;
            case 'item':
              v.itemType = pv == 'number' ? 'number' : 'text';
              break;
            case 'required':
              v.required = pv.isEmpty || pv == 'true' || pv == '1';
              break;
          }
        }
        t.vars.add(v);
        break;
    }
  }
  t.sql = lines.sublist(i).join('\n').trimRight();
  // Make sure every {{var}} in SQL has a definition (keep declared order first).
  t.vars = [
    ...t.vars.where((v) => detectVars(t.sql).contains(v.name)),
    ...syncVars(t.sql, t.vars).where((v) => !t.vars.any((x) => x.name == v.name)),
  ];
  if (t.name.isEmpty) t.name = fallbackName ?? 'Без названия';
  return t;
}

String slugify(String s) {
  const map = {
    'а': 'a', 'б': 'b', 'в': 'v', 'г': 'g', 'д': 'd', 'е': 'e', 'ё': 'e', 'ж': 'zh',
    'з': 'z', 'и': 'i', 'й': 'y', 'к': 'k', 'л': 'l', 'м': 'm', 'н': 'n', 'о': 'o',
    'п': 'p', 'р': 'r', 'с': 's', 'т': 't', 'у': 'u', 'ф': 'f', 'х': 'h', 'ц': 'c',
    'ч': 'ch', 'ш': 'sh', 'щ': 'sch', 'ъ': '', 'ы': 'y', 'ь': '', 'э': 'e', 'ю': 'yu',
    'я': 'ya',
  };
  final b = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    b.write(map[ch] ?? ch);
  }
  final out = b
      .toString()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return out.isEmpty ? 'template' : out;
}
