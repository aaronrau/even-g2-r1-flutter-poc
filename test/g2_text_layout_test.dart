import 'package:even_g2_r1_poc/src/protocol/g2_text_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const layout = G2TextLayout.history;

  test('history layout owns the shared physical and measured bounds', () {
    expect(layout.physicalContentWidthPixels, 576);
    expect(layout.displayHeightPixels, 288);
    expect(layout.wrappingWidthPixels, 620);
    expect(layout.maximumVisibleRows, 10);
    expect(layout.maximumPageCharacters, 2048);
  });

  test('selector text is limited to two measured rows', () {
    final lines = layout.limitLines(
      List<String>.filled(80, 'selector').join(' '),
      2,
    );

    expect(lines, hasLength(2));
    expect(lines.last, endsWith('…'));
    expect(
      lines.every(
        (line) => layout.textWidth(line) <= layout.wrappingWidthPixels,
      ),
      isTrue,
    );
  });

  test('selector blocks stay intact within the shared row budget', () {
    final pages = layout.paginateBlocks<int>(
      <int>[1, 2, 2, 2, 2, 2, 2],
      rowCount: (rows) => rows,
      footerRows: 1,
    );

    expect(pages, <List<int>>[
      <int>[1, 2, 2, 2, 2],
      <int>[2, 2],
    ]);
  });

  test('detail pages repeat the prior final row at the next page top', () {
    final lines = List<String>.generate(20, (index) => 'row $index');
    final pages = layout.paginateLines(lines, rowsPerPage: 9, overlapRows: 1);

    expect(pages, hasLength(3));
    expect(pages.first, hasLength(9));
    expect(pages[1].first, pages.first.last);
    expect(pages[2].first, pages[1].last);
    expect(pages.last.last, 'row 19');
  });
}
