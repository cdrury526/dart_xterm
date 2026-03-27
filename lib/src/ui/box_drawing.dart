import 'dart:ui';

/// Custom renderer for box-drawing characters (U+2500-U+257F) and
/// block elements (U+2580-U+259F). These are drawn using Canvas primitives
/// instead of font glyphs to ensure pixel-perfect rendering at any cell size,
/// matching the behavior of xterm.js and iTerm2.

/// Returns true if [charCode] is a box-drawing or block element character
/// that should be custom-rendered.
bool isBoxDrawingChar(int charCode) {
  return charCode >= 0x2500 && charCode <= 0x259F;
}

/// Draws a box-drawing or block element character on [canvas] at [offset]
/// within a cell of [cellSize], using the given [color].
void drawBoxDrawingChar(
  Canvas canvas,
  Offset offset,
  Size cellSize,
  int charCode,
  Color color,
) {
  if (charCode >= 0x2580 && charCode <= 0x259F) {
    _drawBlockElement(canvas, offset, cellSize, charCode, color);
    return;
  }

  final segments = _boxDrawingSegments[charCode];
  if (segments == null) return;

  final cx = offset.dx + cellSize.width / 2;
  final cy = offset.dy + cellSize.height / 2;
  final left = offset.dx;
  final right = offset.dx + cellSize.width;
  final top = offset.dy;
  final bottom = offset.dy + cellSize.height;

  for (final seg in segments) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = seg.heavy ? 2.0 : 1.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt;

    final x1 = _resolveX(seg.from, left, cx, right);
    final y1 = _resolveY(seg.from, top, cy, bottom);
    final x2 = _resolveX(seg.to, left, cx, right);
    final y2 = _resolveY(seg.to, top, cy, bottom);

    // Round to nearest pixel for crisp lines
    canvas.drawLine(
      Offset(x1.roundToDouble(), y1.roundToDouble()),
      Offset(x2.roundToDouble(), y2.roundToDouble()),
      paint,
    );
  }
}

double _resolveX(_Anchor a, double left, double cx, double right) {
  switch (a) {
    case _Anchor.left:
      return left;
    case _Anchor.right:
      return right;
    case _Anchor.top:
    case _Anchor.bottom:
    case _Anchor.center:
      return cx;
  }
}

double _resolveY(_Anchor a, double top, double cy, double bottom) {
  switch (a) {
    case _Anchor.top:
      return top;
    case _Anchor.bottom:
      return bottom;
    case _Anchor.left:
    case _Anchor.right:
    case _Anchor.center:
      return cy;
  }
}

enum _Anchor { left, right, top, bottom, center }

class _Seg {
  final _Anchor from;
  final _Anchor to;
  final bool heavy;

  const _Seg(this.from, this.to, [this.heavy = false]);
}

// Shorthand constructors
const _l2c = _Seg(_Anchor.left, _Anchor.center);
const _c2r = _Seg(_Anchor.center, _Anchor.right);
const _t2c = _Seg(_Anchor.top, _Anchor.center);
const _c2b = _Seg(_Anchor.center, _Anchor.bottom);
const _l2r = _Seg(_Anchor.left, _Anchor.right);
const _t2b = _Seg(_Anchor.top, _Anchor.bottom);

const _l2cH = _Seg(_Anchor.left, _Anchor.center, true);
const _c2rH = _Seg(_Anchor.center, _Anchor.right, true);
const _t2cH = _Seg(_Anchor.top, _Anchor.center, true);
const _c2bH = _Seg(_Anchor.center, _Anchor.bottom, true);
const _l2rH = _Seg(_Anchor.left, _Anchor.right, true);
const _t2bH = _Seg(_Anchor.top, _Anchor.bottom, true);

/// Box-drawing character definitions.
/// Each character is defined as a list of line segments from anchor to anchor.
const _boxDrawingSegments = <int, List<_Seg>>{
  // ─ Light horizontal
  0x2500: [_l2r],
  // ━ Heavy horizontal
  0x2501: [_l2rH],
  // │ Light vertical
  0x2502: [_t2b],
  // ┃ Heavy vertical
  0x2503: [_t2bH],

  // ┄ Light triple dash horizontal
  0x2504: [_l2r],
  // ┅ Heavy triple dash horizontal
  0x2505: [_l2rH],
  // ┆ Light triple dash vertical
  0x2506: [_t2b],
  // ┇ Heavy triple dash vertical
  0x2507: [_t2bH],

  // ┈ Light quadruple dash horizontal
  0x2508: [_l2r],
  // ┉ Heavy quadruple dash horizontal
  0x2509: [_l2rH],
  // ┊ Light quadruple dash vertical
  0x250A: [_t2b],
  // ┋ Heavy quadruple dash vertical
  0x250B: [_t2bH],

  // ┌ Light down and right
  0x250C: [_c2r, _c2b],
  // ┍ Down light and right heavy
  0x250D: [_c2rH, _c2b],
  // ┎ Down heavy and right light
  0x250E: [_c2r, _c2bH],
  // ┏ Heavy down and right
  0x250F: [_c2rH, _c2bH],

  // ┐ Light down and left
  0x2510: [_l2c, _c2b],
  // ┑ Down light and left heavy
  0x2511: [_l2cH, _c2b],
  // ┒ Down heavy and left light
  0x2512: [_l2c, _c2bH],
  // ┓ Heavy down and left
  0x2513: [_l2cH, _c2bH],

  // └ Light up and right
  0x2514: [_c2r, _t2c],
  // ┕ Up light and right heavy
  0x2515: [_c2rH, _t2c],
  // ┖ Up heavy and right light
  0x2516: [_c2r, _t2cH],
  // ┗ Heavy up and right
  0x2517: [_c2rH, _t2cH],

  // ┘ Light up and left
  0x2518: [_l2c, _t2c],
  // ┙ Up light and left heavy
  0x2519: [_l2cH, _t2c],
  // ┚ Up heavy and left light
  0x251A: [_l2c, _t2cH],
  // ┛ Heavy up and left
  0x251B: [_l2cH, _t2cH],

  // ├ Light vertical and right
  0x251C: [_t2b, _c2r],
  // ┝ Vertical light and right heavy
  0x251D: [_t2b, _c2rH],
  // ┞ Up heavy and right down light
  0x251E: [_t2cH, _c2r, _c2b],
  // ┟ Down heavy and right up light
  0x251F: [_t2c, _c2r, _c2bH],
  // ┠ Vertical heavy and right light
  0x2520: [_t2bH, _c2r],
  // ┡ Down light and right up heavy
  0x2521: [_t2cH, _c2rH, _c2b],
  // ┢ Up light and right down heavy
  0x2522: [_t2c, _c2rH, _c2bH],
  // ┣ Heavy vertical and right
  0x2523: [_t2bH, _c2rH],

  // ┤ Light vertical and left
  0x2524: [_t2b, _l2c],
  // ┥ Vertical light and left heavy
  0x2525: [_t2b, _l2cH],
  // ┦ Up heavy and left down light
  0x2526: [_t2cH, _l2c, _c2b],
  // ┧ Down heavy and left up light
  0x2527: [_t2c, _l2c, _c2bH],
  // ┨ Vertical heavy and left light
  0x2528: [_t2bH, _l2c],
  // ┩ Down light and left up heavy
  0x2529: [_t2cH, _l2cH, _c2b],
  // ┪ Up light and left down heavy
  0x252A: [_t2c, _l2cH, _c2bH],
  // ┫ Heavy vertical and left
  0x252B: [_t2bH, _l2cH],

  // ┬ Light down and horizontal
  0x252C: [_l2r, _c2b],
  // ┭ Left heavy and right down light
  0x252D: [_l2cH, _c2r, _c2b],
  // ┮ Right heavy and left down light
  0x252E: [_l2c, _c2rH, _c2b],
  // ┯ Down light and horizontal heavy
  0x252F: [_l2rH, _c2b],
  // ┰ Down heavy and horizontal light
  0x2530: [_l2r, _c2bH],
  // ┱ Right light and left down heavy
  0x2531: [_l2cH, _c2r, _c2bH],
  // ┲ Left light and right down heavy
  0x2532: [_l2c, _c2rH, _c2bH],
  // ┳ Heavy down and horizontal
  0x2533: [_l2rH, _c2bH],

  // ┴ Light up and horizontal
  0x2534: [_l2r, _t2c],
  // ┵ Left heavy and right up light
  0x2535: [_l2cH, _c2r, _t2c],
  // ┶ Right heavy and left up light
  0x2536: [_l2c, _c2rH, _t2c],
  // ┷ Up light and horizontal heavy
  0x2537: [_l2rH, _t2c],
  // ┸ Up heavy and horizontal light
  0x2538: [_l2r, _t2cH],
  // ┹ Right light and left up heavy
  0x2539: [_l2cH, _c2r, _t2cH],
  // ┺ Left light and right up heavy
  0x253A: [_l2c, _c2rH, _t2cH],
  // ┻ Heavy up and horizontal
  0x253B: [_l2rH, _t2cH],

  // ┼ Light vertical and horizontal
  0x253C: [_l2r, _t2b],
  // ┽ Left heavy and right vertical light
  0x253D: [_l2cH, _c2r, _t2b],
  // ┾ Right heavy and left vertical light
  0x253E: [_l2c, _c2rH, _t2b],
  // ┿ Vertical light and horizontal heavy
  0x253F: [_l2rH, _t2b],
  // ╀ Up heavy and down horizontal light
  0x2540: [_l2r, _t2cH, _c2b],
  // ╁ Down heavy and up horizontal light
  0x2541: [_l2r, _t2c, _c2bH],
  // ╂ Vertical heavy and horizontal light
  0x2542: [_l2r, _t2bH],
  // ╃ Left up heavy and right down light
  0x2543: [_l2cH, _c2r, _t2cH, _c2b],
  // ╄ Right up heavy and left down light
  0x2544: [_l2c, _c2rH, _t2cH, _c2b],
  // ╅ Left down heavy and right up light
  0x2545: [_l2cH, _c2r, _t2c, _c2bH],
  // ╆ Right down heavy and left up light
  0x2546: [_l2c, _c2rH, _t2c, _c2bH],
  // ╇ Down light and up horizontal heavy
  0x2547: [_l2rH, _t2cH, _c2b],
  // ╈ Up light and down horizontal heavy
  0x2548: [_l2rH, _t2c, _c2bH],
  // ╉ Right light and left vertical heavy
  0x2549: [_l2cH, _c2r, _t2bH],
  // ╊ Left light and right vertical heavy
  0x254A: [_l2c, _c2rH, _t2bH],
  // ╋ Heavy vertical and horizontal
  0x254B: [_l2rH, _t2bH],

  // ╌ Light double dash horizontal
  0x254C: [_l2r],
  // ╍ Heavy double dash horizontal
  0x254D: [_l2rH],
  // ╎ Light double dash vertical
  0x254E: [_t2b],
  // ╏ Heavy double dash vertical
  0x254F: [_t2bH],

  // ═ Double horizontal
  0x2550: [_l2r], // rendered as single for simplicity
  // ║ Double vertical
  0x2551: [_t2b],

  // Double-line corners and intersections (simplified to single lines)
  // ╒ Down single and right double
  0x2552: [_c2r, _c2b],
  // ╓ Down double and right single
  0x2553: [_c2r, _c2b],
  // ╔ Double down and right
  0x2554: [_c2r, _c2b],
  // ╕ Down single and left double
  0x2555: [_l2c, _c2b],
  // ╖ Down double and left single
  0x2556: [_l2c, _c2b],
  // ╗ Double down and left
  0x2557: [_l2c, _c2b],
  // ╘ Up single and right double
  0x2558: [_c2r, _t2c],
  // ╙ Up double and right single
  0x2559: [_c2r, _t2c],
  // ╚ Double up and right
  0x255A: [_c2r, _t2c],
  // ╛ Up single and left double
  0x255B: [_l2c, _t2c],
  // ╜ Up double and left single
  0x255C: [_l2c, _t2c],
  // ╝ Double up and left
  0x255D: [_l2c, _t2c],
  // ╞ Vertical single and right double
  0x255E: [_t2b, _c2r],
  // ╟ Vertical double and right single
  0x255F: [_t2b, _c2r],
  // ╠ Double vertical and right
  0x2560: [_t2b, _c2r],
  // ╡ Vertical single and left double
  0x2561: [_t2b, _l2c],
  // ╢ Vertical double and left single
  0x2562: [_t2b, _l2c],
  // ╣ Double vertical and left
  0x2563: [_t2b, _l2c],
  // ╤ Down single and horizontal double
  0x2564: [_l2r, _c2b],
  // ╥ Down double and horizontal single
  0x2565: [_l2r, _c2b],
  // ╦ Double down and horizontal
  0x2566: [_l2r, _c2b],
  // ╧ Up single and horizontal double
  0x2567: [_l2r, _t2c],
  // ╨ Up double and horizontal single
  0x2568: [_l2r, _t2c],
  // ╩ Double up and horizontal
  0x2569: [_l2r, _t2c],
  // ╪ Vertical single and horizontal double
  0x256A: [_l2r, _t2b],
  // ╫ Vertical double and horizontal single
  0x256B: [_l2r, _t2b],
  // ╬ Double vertical and horizontal
  0x256C: [_l2r, _t2b],

  // ╭ Light arc down and right (rounded corner)
  0x256D: [_c2r, _c2b],
  // ╮ Light arc down and left
  0x256E: [_l2c, _c2b],
  // ╯ Light arc up and left
  0x256F: [_l2c, _t2c],
  // ╰ Light arc up and right
  0x2570: [_c2r, _t2c],

  // ╱ Light diagonal upper right to lower left
  0x2571: [_l2r], // approximate
  // ╲ Light diagonal upper left to lower right
  0x2572: [_l2r], // approximate
  // ╳ Light diagonal cross
  0x2573: [_l2r], // approximate

  // ╴ Light left
  0x2574: [_l2c],
  // ╵ Light up
  0x2575: [_t2c],
  // ╶ Light right
  0x2576: [_c2r],
  // ╷ Light down
  0x2577: [_c2b],
  // ╸ Heavy left
  0x2578: [_l2cH],
  // ╹ Heavy up
  0x2579: [_t2cH],
  // ╺ Heavy right
  0x257A: [_c2rH],
  // ╻ Heavy down
  0x257B: [_c2bH],
  // ╼ Light left and heavy right
  0x257C: [_l2c, _c2rH],
  // ╽ Light up and heavy down
  0x257D: [_t2c, _c2bH],
  // ╾ Heavy left and light right
  0x257E: [_l2cH, _c2r],
  // ╿ Heavy up and light down
  0x257F: [_t2cH, _c2b],
};

void _drawBlockElement(
  Canvas canvas,
  Offset offset,
  Size cellSize,
  int charCode,
  Color color,
) {
  final paint = Paint()
    ..color = color
    ..style = PaintingStyle.fill;

  final w = cellSize.width;
  final h = cellSize.height;
  final x = offset.dx;
  final y = offset.dy;

  switch (charCode) {
    // ▀ Upper half block
    case 0x2580:
      canvas.drawRect(Rect.fromLTWH(x, y, w, h / 2), paint);
    // ▁ Lower one eighth block
    case 0x2581:
      canvas.drawRect(Rect.fromLTWH(x, y + h * 7 / 8, w, h / 8), paint);
    // ▂ Lower one quarter block
    case 0x2582:
      canvas.drawRect(Rect.fromLTWH(x, y + h * 3 / 4, w, h / 4), paint);
    // ▃ Lower three eighths block
    case 0x2583:
      canvas.drawRect(Rect.fromLTWH(x, y + h * 5 / 8, w, h * 3 / 8), paint);
    // ▄ Lower half block
    case 0x2584:
      canvas.drawRect(Rect.fromLTWH(x, y + h / 2, w, h / 2), paint);
    // ▅ Lower five eighths block
    case 0x2585:
      canvas.drawRect(Rect.fromLTWH(x, y + h * 3 / 8, w, h * 5 / 8), paint);
    // ▆ Lower three quarters block
    case 0x2586:
      canvas.drawRect(Rect.fromLTWH(x, y + h / 4, w, h * 3 / 4), paint);
    // ▇ Lower seven eighths block
    case 0x2587:
      canvas.drawRect(Rect.fromLTWH(x, y + h / 8, w, h * 7 / 8), paint);
    // █ Full block
    case 0x2588:
      canvas.drawRect(Rect.fromLTWH(x, y, w, h), paint);
    // ▉ Left seven eighths block
    case 0x2589:
      canvas.drawRect(Rect.fromLTWH(x, y, w * 7 / 8, h), paint);
    // ▊ Left three quarters block
    case 0x258A:
      canvas.drawRect(Rect.fromLTWH(x, y, w * 3 / 4, h), paint);
    // ▋ Left five eighths block
    case 0x258B:
      canvas.drawRect(Rect.fromLTWH(x, y, w * 5 / 8, h), paint);
    // ▌ Left half block
    case 0x258C:
      canvas.drawRect(Rect.fromLTWH(x, y, w / 2, h), paint);
    // ▍ Left three eighths block
    case 0x258D:
      canvas.drawRect(Rect.fromLTWH(x, y, w * 3 / 8, h), paint);
    // ▎ Left one quarter block
    case 0x258E:
      canvas.drawRect(Rect.fromLTWH(x, y, w / 4, h), paint);
    // ▏ Left one eighth block
    case 0x258F:
      canvas.drawRect(Rect.fromLTWH(x, y, w / 8, h), paint);
    // ▐ Right half block
    case 0x2590:
      canvas.drawRect(Rect.fromLTWH(x + w / 2, y, w / 2, h), paint);
    // ░ Light shade
    case 0x2591:
      paint.color = color.withValues(alpha: 0.25);
      canvas.drawRect(Rect.fromLTWH(x, y, w, h), paint);
    // ▒ Medium shade
    case 0x2592:
      paint.color = color.withValues(alpha: 0.5);
      canvas.drawRect(Rect.fromLTWH(x, y, w, h), paint);
    // ▓ Dark shade
    case 0x2593:
      paint.color = color.withValues(alpha: 0.75);
      canvas.drawRect(Rect.fromLTWH(x, y, w, h), paint);
    // ▔ Upper one eighth block
    case 0x2594:
      canvas.drawRect(Rect.fromLTWH(x, y, w, h / 8), paint);
    // ▕ Right one eighth block
    case 0x2595:
      canvas.drawRect(Rect.fromLTWH(x + w * 7 / 8, y, w / 8, h), paint);
    // ▖ Quadrant lower left
    case 0x2596:
      canvas.drawRect(Rect.fromLTWH(x, y + h / 2, w / 2, h / 2), paint);
    // ▗ Quadrant lower right
    case 0x2597:
      canvas.drawRect(Rect.fromLTWH(x + w / 2, y + h / 2, w / 2, h / 2), paint);
    // ▘ Quadrant upper left
    case 0x2598:
      canvas.drawRect(Rect.fromLTWH(x, y, w / 2, h / 2), paint);
    // ▙ Quadrant upper left and lower left and lower right
    case 0x2599:
      canvas.drawRect(Rect.fromLTWH(x, y, w / 2, h / 2), paint);
      canvas.drawRect(Rect.fromLTWH(x, y + h / 2, w, h / 2), paint);
    // ▚ Quadrant upper left and lower right
    case 0x259A:
      canvas.drawRect(Rect.fromLTWH(x, y, w / 2, h / 2), paint);
      canvas.drawRect(Rect.fromLTWH(x + w / 2, y + h / 2, w / 2, h / 2), paint);
    // ▛ Quadrant upper left and upper right and lower left
    case 0x259B:
      canvas.drawRect(Rect.fromLTWH(x, y, w, h / 2), paint);
      canvas.drawRect(Rect.fromLTWH(x, y + h / 2, w / 2, h / 2), paint);
    // ▜ Quadrant upper left and upper right and lower right
    case 0x259C:
      canvas.drawRect(Rect.fromLTWH(x, y, w, h / 2), paint);
      canvas.drawRect(Rect.fromLTWH(x + w / 2, y + h / 2, w / 2, h / 2), paint);
    // ▝ Quadrant upper right
    case 0x259D:
      canvas.drawRect(Rect.fromLTWH(x + w / 2, y, w / 2, h / 2), paint);
    // ▞ Quadrant upper right and lower left
    case 0x259E:
      canvas.drawRect(Rect.fromLTWH(x + w / 2, y, w / 2, h / 2), paint);
      canvas.drawRect(Rect.fromLTWH(x, y + h / 2, w / 2, h / 2), paint);
    // ▟ Quadrant upper right and lower left and lower right
    case 0x259F:
      canvas.drawRect(Rect.fromLTWH(x + w / 2, y, w / 2, h / 2), paint);
      canvas.drawRect(Rect.fromLTWH(x, y + h / 2, w, h / 2), paint);
  }
}
