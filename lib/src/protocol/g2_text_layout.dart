import 'g2_protocol.dart';

/// Shared host-side text layout for the full-height G2 history surface.
///
/// G2 firmware wraps text itself, but it does not expose its measured line
/// breaks. The host therefore mirrors the firmware font closely enough to
/// create deterministic selector and detail pages before sending them.
final class G2TextLayout {
  // EvenHub text-container upgrades accept at most 2,000 characters. Keep
  // every pre-paginated selector/detail update inside that firmware boundary.
  static const int historyMaximumPageCharacters = 2000;

  const G2TextLayout({
    required this.displayWidthPixels,
    required this.displayHeightPixels,
    required this.borderWidthPixels,
    required this.paddingPixels,
    required this.measurementSafetyPixels,
    required this.observedWidthCalibrationPixels,
    required this.maximumVisibleRows,
    required this.maximumPageCharacters,
  });

  /// Layout used by both the one-press history selector and its detail view.
  static const history = G2TextLayout(
    displayWidthPixels: G2Protocol.fullPageTextWidth,
    displayHeightPixels: G2Protocol.fullPageTextHeight,
    borderWidthPixels: G2Protocol.expandedTextBorderWidth,
    paddingPixels: G2Protocol.expandedTextPaddingLength,
    measurementSafetyPixels: 18,
    observedWidthCalibrationPixels: 50,
    maximumVisibleRows: 9,
    maximumPageCharacters: historyMaximumPageCharacters,
  );

  final int displayWidthPixels;
  final int displayHeightPixels;
  final int borderWidthPixels;
  final int paddingPixels;
  final int measurementSafetyPixels;

  /// Compensates for measuring standalone glyph advances without the
  /// firmware font's pair kerning. Fifty units is about five average glyphs
  /// on the representative glasses and does not change the physical bounds.
  final int observedWidthCalibrationPixels;
  final int maximumVisibleRows;
  final int maximumPageCharacters;

  int get physicalContentWidthPixels =>
      displayWidthPixels - (2 * (borderWidthPixels + paddingPixels));

  int get wrappingWidthPixels =>
      physicalContentWidthPixels -
      measurementSafetyPixels +
      observedWidthCalibrationPixels;

  String oneLine(String value) => value.trim().replaceAll(RegExp(r'\s+'), ' ');

  List<String> wrapText(String value) {
    final lines = <String>[];
    final normalized = value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    for (final sourceLine in normalized.split('\n')) {
      final paragraph = sourceLine
          .replaceAll(RegExp(r'[\t\f\v ]+'), ' ')
          .trim();
      if (paragraph.isEmpty) {
        lines.add('');
      } else {
        lines.addAll(wrapParagraph(paragraph));
      }
    }
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    return lines;
  }

  List<String> limitLines(
    String value,
    int maximumLines, {
    int? maximumWidthPixels,
  }) {
    if (maximumLines < 1) {
      throw ArgumentError.value(maximumLines, 'maximumLines', 'must be >= 1');
    }
    final resolvedWidth = maximumWidthPixels ?? wrappingWidthPixels;
    final wrapped = wrapParagraph(value, maximumWidthPixels: resolvedWidth);
    if (wrapped.length <= maximumLines) {
      return wrapped;
    }
    final visible = wrapped.take(maximumLines).toList(growable: false);
    visible[visible.length - 1] = appendEllipsis(
      visible.last,
      maximumWidthPixels: resolvedWidth,
    );
    return visible;
  }

  List<String> wrapParagraph(String value, {int? maximumWidthPixels}) {
    final resolvedWidth = maximumWidthPixels ?? wrappingWidthPixels;
    final words = value.split(' ').where((word) => word.isNotEmpty);
    final lines = <String>[];
    var line = '';
    for (final sourceWord in words) {
      var remaining = sourceWord;
      while (textWidth(remaining) > resolvedWidth) {
        if (line.isNotEmpty) {
          lines.add(line);
          line = '';
        }
        final runes = remaining.runes.toList(growable: false);
        var width = 0;
        var splitAt = 0;
        while (splitAt < runes.length) {
          final nextWidth = width + runeWidth(runes[splitAt]);
          if (nextWidth > resolvedWidth && splitAt > 0) {
            break;
          }
          width = nextWidth;
          splitAt++;
        }
        lines.add(String.fromCharCodes(runes.take(splitAt)));
        remaining = String.fromCharCodes(runes.skip(splitAt));
      }
      if (remaining.isEmpty) {
        continue;
      }
      final candidate = line.isEmpty ? remaining : '$line $remaining';
      if (textWidth(candidate) <= resolvedWidth) {
        line = candidate;
      } else {
        lines.add(line);
        line = remaining;
      }
    }
    if (line.isNotEmpty) {
      lines.add(line);
    }
    return lines;
  }

  /// Packs indivisible row blocks into pages. Selector entries use this so an
  /// `Agent - content` continuation stays with its first row.
  List<List<T>> paginateBlocks<T>(
    List<T> blocks, {
    required int Function(T block) rowCount,
    int headerRows = 0,
    int footerRows = 0,
  }) {
    if (blocks.isEmpty) {
      return <List<T>>[];
    }
    if (headerRows < 0 || headerRows >= maximumVisibleRows) {
      throw ArgumentError.value(
        headerRows,
        'headerRows',
        'must be between 0 and maximumVisibleRows - 1',
      );
    }
    if (footerRows < 0 || headerRows + footerRows >= maximumVisibleRows) {
      throw ArgumentError.value(
        footerRows,
        'footerRows',
        'must leave at least one content row after reserved header rows',
      );
    }
    final totalRows = blocks.fold<int>(0, (sum, block) {
      final rows = rowCount(block);
      if (rows < 1) {
        throw ArgumentError.value(rows, 'rowCount', 'must be >= 1');
      }
      return sum + rows;
    });
    if (totalRows <= maximumVisibleRows - headerRows) {
      return <List<T>>[List<T>.of(blocks)];
    }

    final rowBudget = maximumVisibleRows - headerRows - footerRows;
    final pages = <List<T>>[];
    var page = <T>[];
    var usedRows = 0;
    for (final block in blocks) {
      final rows = rowCount(block);
      if (rows > rowBudget) {
        throw ArgumentError.value(
          rows,
          'rowCount',
          'cannot exceed the page row budget',
        );
      }
      if (page.isNotEmpty && usedRows + rows > rowBudget) {
        pages.add(page);
        page = <T>[];
        usedRows = 0;
      }
      page.add(block);
      usedRows += rows;
    }
    if (page.isNotEmpty) {
      pages.add(page);
    }
    return pages;
  }

  /// Pages already-wrapped rows and optionally repeats the final row of one
  /// page at the top of the next page to preserve reading position.
  List<List<String>> paginateLines(
    List<String> lines, {
    required int rowsPerPage,
    int overlapRows = 0,
  }) {
    if (rowsPerPage < 1) {
      throw ArgumentError.value(rowsPerPage, 'rowsPerPage', 'must be >= 1');
    }
    if (overlapRows < 0 || overlapRows >= rowsPerPage) {
      throw ArgumentError.value(
        overlapRows,
        'overlapRows',
        'must be between 0 and rowsPerPage - 1',
      );
    }
    if (lines.isEmpty) {
      return const <List<String>>[
        <String>[''],
      ];
    }

    final pages = <List<String>>[];
    final pageStep = rowsPerPage - overlapRows;
    for (var start = 0; start < lines.length; start += pageStep) {
      final end = (start + rowsPerPage).clamp(0, lines.length);
      pages.add(lines.sublist(start, end));
      if (end == lines.length) {
        break;
      }
    }
    return pages;
  }

  String fitLine(String value, int maximumPixels) {
    if (textWidth(value) <= maximumPixels) {
      return value;
    }
    final runes = value.runes.toList(growable: true);
    while (runes.isNotEmpty &&
        textWidth('${String.fromCharCodes(runes)}…') > maximumPixels) {
      runes.removeLast();
    }
    return '${String.fromCharCodes(runes).trimRight()}…';
  }

  /// Fits [value] after a measured fixed prefix without allowing the combined
  /// row to exceed the wrapping budget.
  String fitLineWithLeading(
    String value, {
    required String leading,
    int? maximumWidthPixels,
  }) {
    final resolvedWidth = maximumWidthPixels ?? wrappingWidthPixels;
    final contentWidth = resolvedWidth - textWidth(leading);
    if (contentWidth <= 0) {
      throw ArgumentError.value(
        leading,
        'leading',
        'must leave positive width for content',
      );
    }
    return '$leading${fitLine(value, contentWidth)}';
  }

  String appendEllipsis(String value, {int? maximumWidthPixels}) {
    final resolvedWidth = maximumWidthPixels ?? wrappingWidthPixels;
    final runes = value.trimRight().runes.toList(growable: true);
    while (runes.isNotEmpty &&
        textWidth('${String.fromCharCodes(runes)}…') > resolvedWidth) {
      runes.removeLast();
    }
    return '${String.fromCharCodes(runes).trimRight()}…';
  }

  int textWidth(String value) =>
      value.runes.fold<int>(0, (width, rune) => width + runeWidth(rune));

  int runeWidth(int rune) {
    if (rune >= 32 && rune <= 126) {
      return _asciiAdvancePixels[rune - 32];
    }
    if (rune == 0x2026) return 10;
    if (rune == 0x2022) return 9;
    if (rune == 0x00b7) return 5;
    if (rune >= 0x0300 && rune <= 0x036f) return 0;
    if ((rune >= 0x2e80 && rune <= 0x9fff) ||
        (rune >= 0xf900 && rune <= 0xfaff) ||
        (rune >= 0xac00 && rune <= 0xd7af)) {
      return 20;
    }
    if (rune >= 0x1f000) return 24;
    return 12;
  }

  // Printable ASCII advances from @evenrealities/pretext 0.1.4.
  static const List<int> _asciiAdvancePixels = <int>[
    5,
    4,
    6,
    15,
    13,
    14,
    16,
    4,
    7,
    7,
    8,
    10,
    5,
    10,
    5,
    8,
    12,
    8,
    12,
    12,
    13,
    12,
    12,
    13,
    12,
    12,
    4,
    5,
    10,
    10,
    10,
    12,
    17,
    14,
    12,
    12,
    12,
    11,
    11,
    12,
    12,
    6,
    9,
    12,
    10,
    16,
    12,
    12,
    12,
    12,
    12,
    12,
    12,
    12,
    14,
    16,
    14,
    14,
    13,
    7,
    8,
    7,
    10,
    9,
    4,
    12,
    11,
    11,
    11,
    11,
    10,
    11,
    11,
    4,
    7,
    10,
    4,
    16,
    11,
    11,
    11,
    11,
    8,
    11,
    8,
    12,
    12,
    16,
    12,
    12,
    10,
    9,
    4,
    9,
    16,
  ];
}
