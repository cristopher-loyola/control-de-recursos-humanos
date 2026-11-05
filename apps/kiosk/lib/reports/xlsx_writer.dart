import 'dart:convert';
import 'dart:typed_data';

/// Estilos disponibles en las celdas.
enum XlsxStyle { normal, header, title, percent, muted, money }

class XlsxCell {
  const XlsxCell(this.value, [this.style = XlsxStyle.normal]);
  final Object? value;
  final XlsxStyle style;
}

class XlsxSheet {
  XlsxSheet(this.name, {this.widths = const [], this.freezeRows = 0});
  final String name;

  /// Ancho de cada columna en caracteres.
  final List<double> widths;

  /// Renglones fijos al desplazarse (encabezados).
  final int freezeRows;
  final rows = <List<XlsxCell>>[];

  void add(List<Object?> values, [XlsxStyle style = XlsxStyle.normal]) => rows
      .add([for (final v in values) v is XlsxCell ? v : XlsxCell(v, style)]);
}

/// Genera un libro .xlsx mínimo (Office Open XML) sin dependencias externas.
Uint8List buildXlsx(List<XlsxSheet> sheets) {
  final files = <String, String>{
    '[Content_Types].xml':
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '${[for (var i = 1; i <= sheets.length; i++) '<Override PartName="/xl/worksheets/sheet$i.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'].join()}'
        '</Types>',
    '_rels/.rels':
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>',
    'xl/workbook.xml':
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'
        '${[for (var i = 0; i < sheets.length; i++) '<sheet name="${_escape(_sheetName(sheets[i].name))}" sheetId="${i + 1}" r:id="rId${i + 1}"/>'].join()}'
        '</sheets></workbook>',
    'xl/_rels/workbook.xml.rels':
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '${[for (var i = 1; i <= sheets.length; i++) '<Relationship Id="rId$i" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet$i.xml"/>'].join()}'
        '<Relationship Id="rId${sheets.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        '</Relationships>',
    // Orden de cellXfs = orden de XlsxStyle.
    'xl/styles.xml':
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<fonts count="4">'
        '<font><sz val="11"/><name val="Calibri"/></font>'
        '<font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font>'
        '<font><b/><sz val="14"/><name val="Calibri"/></font>'
        '<font><sz val="11"/><color rgb="FF6B6963"/><name val="Calibri"/></font>'
        '</fonts>'
        '<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>'
        '<fill><patternFill patternType="solid"><fgColor rgb="FF2F5D46"/></patternFill></fill></fills>'
        '<borders count="1"><border/></borders>'
        '<cellStyleXfs count="1"><xf/></cellStyleXfs>'
        '<cellXfs count="6">'
        '<xf fontId="0"/>'
        '<xf fontId="1" fillId="2" applyFont="1" applyFill="1"/>'
        '<xf fontId="2" applyFont="1"/>'
        '<xf fontId="0" numFmtId="9" applyNumberFormat="1"/>'
        '<xf fontId="3" applyFont="1"/>'
        '<xf fontId="0" numFmtId="4" applyNumberFormat="1"/>'
        '</cellXfs></styleSheet>',
  };
  for (var i = 0; i < sheets.length; i++) {
    files['xl/worksheets/sheet${i + 1}.xml'] = _sheetXml(sheets[i]);
  }
  return _zip({
    for (final entry in files.entries) entry.key: utf8.encode(entry.value),
  });
}

String _sheetXml(XlsxSheet sheet) {
  final out = StringBuffer(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
  );
  if (sheet.freezeRows > 0) {
    out.write(
      '<sheetViews><sheetView workbookViewId="0"><pane ySplit="${sheet.freezeRows}" '
      'topLeftCell="A${sheet.freezeRows + 1}" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>',
    );
  }
  if (sheet.widths.isNotEmpty) {
    out.write('<cols>');
    for (var i = 0; i < sheet.widths.length; i++) {
      out.write(
        '<col min="${i + 1}" max="${i + 1}" width="${sheet.widths[i]}" customWidth="1"/>',
      );
    }
    out.write('</cols>');
  }
  out.write('<sheetData>');
  for (var r = 0; r < sheet.rows.length; r++) {
    out.write('<row r="${r + 1}">');
    final row = sheet.rows[r];
    for (var c = 0; c < row.length; c++) {
      final cell = row[c];
      final ref = '${_column(c)}${r + 1}';
      final style = cell.style.index == 0 ? '' : ' s="${cell.style.index}"';
      final value = cell.value;
      if (value == null) {
        if (style.isNotEmpty) out.write('<c r="$ref"$style/>');
      } else if (value is num) {
        out.write('<c r="$ref"$style><v>$value</v></c>');
      } else {
        out.write(
          '<c r="$ref"$style t="inlineStr"><is><t xml:space="preserve">${_escape('$value')}</t></is></c>',
        );
      }
    }
    out.write('</row>');
  }
  out.write('</sheetData></worksheet>');
  return out.toString();
}

String _column(int index) {
  var n = index + 1;
  final letters = StringBuffer();
  while (n > 0) {
    final rem = (n - 1) % 26;
    letters.write(String.fromCharCode(65 + rem));
    n = (n - 1) ~/ 26;
  }
  return letters.toString().split('').reversed.join();
}

String _sheetName(String name) {
  final clean = name.replaceAll(RegExp(r'[\\/?*\[\]:]'), ' ').trim();
  return clean.length > 31 ? clean.substring(0, 31) : clean;
}

String _escape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    // Caracteres de control no permitidos en XML.
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc = _crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFF;
}

/// Zip sin compresión (método "store"): suficiente para estos archivos.
Uint8List _zip(Map<String, List<int>> files) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  var count = 0;
  for (final entry in files.entries) {
    final name = utf8.encode(entry.key);
    final data = entry.value;
    final crc = _crc32(data);
    final offset = out.length;
    final local = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 0x0800, Endian.little) // nombres en UTF-8
      ..setUint16(8, 0, Endian.little)
      ..setUint16(10, 0, Endian.little)
      ..setUint16(12, 0x21, Endian.little) // 1 ene 1980
      ..setUint32(14, crc, Endian.little)
      ..setUint32(18, data.length, Endian.little)
      ..setUint32(22, data.length, Endian.little)
      ..setUint16(26, name.length, Endian.little)
      ..setUint16(28, 0, Endian.little);
    out
      ..add(local.buffer.asUint8List())
      ..add(name)
      ..add(data);
    final header = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(8, 0x0800, Endian.little)
      ..setUint16(10, 0, Endian.little)
      ..setUint16(12, 0, Endian.little)
      ..setUint16(14, 0x21, Endian.little)
      ..setUint32(16, crc, Endian.little)
      ..setUint32(20, data.length, Endian.little)
      ..setUint32(24, data.length, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central
      ..add(header.buffer.asUint8List())
      ..add(name);
    count++;
  }
  final centralOffset = out.length;
  final centralBytes = central.takeBytes();
  out.add(centralBytes);
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, count, Endian.little)
    ..setUint16(10, count, Endian.little)
    ..setUint32(12, centralBytes.length, Endian.little)
    ..setUint32(16, centralOffset, Endian.little);
  out.add(end.buffer.asUint8List());
  return out.takeBytes();
}
