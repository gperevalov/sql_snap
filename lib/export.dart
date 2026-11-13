import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart' as xl;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'models.dart';

/// How a result can be sent to other apps via the Android share sheet.
enum ShareFormat { xlsx, csv, text }

/// Numbers that are safe to store as Excel numbers: no leading zeros (IDs like 007)
/// and not longer than Excel's 15-digit precision.
final _excelNumber = RegExp(r'^-?(0|[1-9]\d{0,14})(\.\d+)?$');

/// Text longer than this is sent as a .txt file: Android can't pass ~1 MB through the share
/// intent (TransactionTooLargeException), and messengers cut long messages anyway.
const maxShareTextLength = 50000;

/// What [shareResult] actually did — lets the UI explain a fallback.
enum ShareOutcome { shared, sentAsFile }

/// Builds the file (or text) and opens the share sheet (Telegram, mail, Drive…).
Future<ShareOutcome> shareResult(QueryResult r, String title, ShareFormat format) async {
  final name = _fileName(title);
  switch (format) {
    case ShareFormat.text:
      final text = r.toTsv();
      if (text.length > maxShareTextLength) {
        await _shareFile(utf8.encode(text), '$name.txt', 'text/plain', title);
        return ShareOutcome.sentAsFile;
      }
      await SharePlus.instance.share(ShareParams(text: text, subject: title));
    case ShareFormat.csv:
      // BOM so that Excel opens UTF-8 (Cyrillic) correctly.
      final bytes = utf8.encode('﻿${r.toCsv()}');
      await _shareFile(bytes, '$name.csv', 'text/csv', title);
    case ShareFormat.xlsx:
      await _shareFile(_toXlsx(r, title), '$name.xlsx',
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', title);
  }
  return ShareOutcome.shared;
}

Future<void> _shareFile(List<int> bytes, String fileName, String mime, String title) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$fileName');
  await file.writeAsBytes(bytes, flush: true);
  await SharePlus.instance.share(ShareParams(
    files: [XFile(file.path, mimeType: mime)],
    subject: title,
  ));
}

List<int> _toXlsx(QueryResult r, String title) {
  final book = xl.Excel.createExcel();
  final defaultSheet = book.getDefaultSheet()!;
  final sheetName = _sheetName(title);
  book.rename(defaultSheet, sheetName);
  final sheet = book[sheetName];
  sheet.appendRow([for (final c in r.columns) xl.TextCellValue(c)]);
  for (final row in r.rows) {
    sheet.appendRow([for (final v in row) _cell(v)]);
  }
  return book.encode()!;
}

xl.CellValue? _cell(String? v) {
  if (v == null) return null;
  if (_excelNumber.hasMatch(v)) {
    final i = int.tryParse(v);
    if (i != null) return xl.IntCellValue(i);
    final d = double.tryParse(v);
    if (d != null) return xl.DoubleCellValue(d);
  }
  return xl.TextCellValue(v);
}

String _fileName(String title) {
  final clean = title.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_').replaceAll(RegExp(r'_+'), '_');
  final now = DateTime.now();
  String two(int x) => x.toString().padLeft(2, '0');
  final stamp = '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}';
  return '${clean.isEmpty ? 'result' : clean}_$stamp';
}

/// Excel sheet names: max 31 chars, no []:*?/\
String _sheetName(String title) {
  final s = title.replaceAll(RegExp(r'[\[\]:*?/\\]'), ' ').trim();
  if (s.isEmpty) return 'Результат';
  return s.length > 31 ? s.substring(0, 31) : s;
}
