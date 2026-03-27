import 'dart:math' show max, min;

import 'package:dart_xterm/src/core/buffer/cell_offset.dart';
import 'package:dart_xterm/src/core/buffer/line.dart';
import 'package:dart_xterm/src/core/buffer/range_line.dart';
import 'package:dart_xterm/src/core/buffer/range.dart';
import 'package:dart_xterm/src/core/charset.dart';
import 'package:dart_xterm/src/core/cursor.dart';
import 'package:dart_xterm/src/core/reflow.dart';
import 'package:dart_xterm/src/core/state.dart';
import 'package:dart_xterm/src/utils/circular_buffer.dart';
import 'package:dart_xterm/src/utils/unicode_v11.dart';

class Buffer {
  final TerminalState terminal;

  final int maxLines;

  final bool isAltBuffer;

  /// Characters that break selection when calling [getWordBoundary]. If null,
  /// defaults to [defaultWordSeparators].
  final Set<int>? wordSeparators;

  Buffer(
    this.terminal, {
    required this.maxLines,
    required this.isAltBuffer,
    this.wordSeparators,
  }) {
    for (int i = 0; i < terminal.viewHeight; i++) {
      lines.push(_newEmptyLine());
    }

    resetVerticalMargins();
  }

  int _cursorX = 0;

  int _cursorY = 0;

  late int _marginTop;

  late int _marginBottom;

  var _savedCursorX = 0;

  var _savedCursorY = 0;

  final _savedCursorStyle = CursorStyle();

  final charset = Charset();

  /// Width of the viewport in columns. Also the index of the last column.
  int get viewWidth => terminal.viewWidth;

  /// Height of the viewport in rows. Also the index of the last line.
  int get viewHeight => terminal.viewHeight;

  /// lines of the buffer. the length of [lines] should always be equal or
  /// greater than [viewHeight].
  late final lines = IndexAwareCircularBuffer<BufferLine>(maxLines);

  /// Total number of lines in the buffer. Always equal or greater than
  /// [viewHeight].
  int get height => lines.length;

  /// Horizontal position of the cursor relative to the top-left cornor of the
  /// screen, starting from 0.
  int get cursorX => _cursorX.clamp(0, terminal.viewWidth - 1);

  /// Vertical position of the cursor relative to the top-left cornor of the
  /// screen, starting from 0.
  int get cursorY => _cursorY;

  /// Index of the first line in the scroll region.
  int get marginTop => _marginTop;

  /// Index of the last line in the scroll region.
  int get marginBottom => _marginBottom;

  /// The number of lines above the viewport.
  int get scrollBack => height - viewHeight;

  /// Vertical position of the cursor relative to the top of the buffer,
  /// starting from 0.
  int get absoluteCursorY => _cursorY + scrollBack;

  /// Absolute index of the first line in the scroll region.
  int get absoluteMarginTop => _marginTop + scrollBack;

  /// Absolute index of the last line in the scroll region.
  int get absoluteMarginBottom => _marginBottom + scrollBack;

  /// Writes data to the _terminal. Terminal sequences or special characters are
  /// not interpreted and directly added to the buffer.
  ///
  /// See also: [Terminal.write]
  void write(String text) {
    for (var char in text.runes) {
      writeChar(char);
    }
  }

  /// Writes a single character to the _terminal. Escape sequences or special
  /// characters are not interpreted and directly added to the buffer.
  ///
  /// See also: [Terminal.writeChar]
  void writeChar(int codePoint) {
    codePoint = charset.translate(codePoint);

    final cellWidth = unicodeV11.wcwidth(codePoint);
    if (_cursorX >= terminal.viewWidth) {
      index();
      setCursorX(0);
      if (terminal.autoWrapMode) {
        currentLine.isWrapped = true;
      }
    }

    final line = currentLine;
    line.setCell(_cursorX, codePoint, cellWidth, terminal.cursor);

    if (_cursorX < viewWidth) {
      _cursorX++;
    }

    if (cellWidth == 2) {
      writeChar(0);
    }
  }

  /// The line at the current cursor position.
  BufferLine get currentLine {
    return lines[absoluteCursorY];
  }

  void backspace() {
    if (_cursorX == 0 && currentLine.isWrapped) {
      currentLine.isWrapped = false;
      moveCursor(viewWidth - 1, -1);
    } else if (_cursorX == viewWidth) {
      moveCursor(-2, 0);
    } else {
      moveCursor(-1, 0);
    }
  }

  /// Erases the viewport from the cursor position to the end of the buffer,
  /// including the cursor position.
  void eraseDisplayFromCursor() {
    eraseLineFromCursor();

    for (var i = absoluteCursorY + 1; i < height; i++) {
      final line = lines[i];
      line.isWrapped = false;
      line.eraseRange(0, viewWidth, terminal.cursor);
    }
  }

  /// Erases the viewport from the top-left corner to the cursor, including the
  /// cursor.
  void eraseDisplayToCursor() {
    eraseLineToCursor();

    for (var i = 0; i < _cursorY; i++) {
      final line = lines[i + scrollBack];
      line.isWrapped = false;
      line.eraseRange(0, viewWidth, terminal.cursor);
    }
  }

  /// Erases the whole viewport.
  void eraseDisplay() {
    for (var i = 0; i < viewHeight; i++) {
      final line = lines[i + scrollBack];
      line.isWrapped = false;
      line.eraseRange(0, viewWidth, terminal.cursor);
    }
  }

  /// Erases the line from the cursor to the end of the line, including the
  /// cursor position.
  void eraseLineFromCursor() {
    currentLine.isWrapped = false;
    currentLine.eraseRange(_cursorX, viewWidth, terminal.cursor);
  }

  /// Erases the line from the start of the line to the cursor, including the
  /// cursor.
  void eraseLineToCursor() {
    currentLine.isWrapped = false;
    currentLine.eraseRange(0, _cursorX, terminal.cursor);
  }

  /// Erases the line at the current cursor position.
  void eraseLine() {
    currentLine.isWrapped = false;
    currentLine.eraseRange(0, viewWidth, terminal.cursor);
  }

  /// Erases [count] cells starting at the cursor position.
  void eraseChars(int count) {
    final start = _cursorX;
    currentLine.eraseRange(start, start + count, terminal.cursor);
  }

  void scrollDown(int lines) {
    final debug = terminal.debugConfig;
    if (debug.logBufferOperations) {
      debug.onLog?.call('debug', 'buffer',
          'scrollDown($lines) marginTop=$_marginTop marginBottom=$_marginBottom height=${this.lines.length}');
    }

    // Cache absolute positions before mutations — these are computed from
    // lines.length which changes during remove/insert.
    final absTop = absoluteMarginTop;
    final absBottom = absoluteMarginBottom;

    // Match xterm.js: splice-based scroll that maintains index integrity.
    // For each line scrolled: remove from bottom of scroll region, insert
    // blank at top. This shifts all lines down without creating duplicates.
    // The remove+insert pair keeps lines.length constant, so cached absolute
    // positions remain valid across iterations.
    for (var i = 0; i < lines; i++) {
      this.lines.remove(absBottom);
      this.lines.insert(absTop, _newEmptyLine());
    }

    assert(() {
      _verifyBufferIntegrity('scrollDown');
      return true;
    }());
  }

  void scrollUp(int lines) {
    final debug = terminal.debugConfig;
    if (debug.logBufferOperations) {
      debug.onLog?.call('debug', 'buffer',
          'scrollUp($lines) marginTop=$_marginTop marginBottom=$_marginBottom height=${this.lines.length}');
    }

    // Cache absolute positions before mutations — these are computed from
    // lines.length which changes during remove/insert.
    final absTop = absoluteMarginTop;
    final absBottom = absoluteMarginBottom;

    // Match xterm.js: splice-based scroll that maintains index integrity.
    // For each line scrolled: remove from top of scroll region, insert
    // blank at bottom. This shifts all lines up without creating duplicates.
    // The remove+insert pair keeps lines.length constant, so cached absolute
    // positions remain valid across iterations.
    for (var i = 0; i < lines; i++) {
      this.lines.remove(absTop);
      this.lines.insert(absBottom, _newEmptyLine());
    }

    assert(() {
      _verifyBufferIntegrity('scrollUp');
      return true;
    }());
  }

  /// https://vt100.net/docs/vt100-ug/chapter3.html#IND IND – Index
  ///
  /// ESC D
  ///
  /// [index] causes the active position to move downward one line without
  /// changing the column position. If the active position is at the bottom
  /// margin, a scroll up is performed.
  void index() {
    if (isInVerticalMargin) {
      if (_cursorY == _marginBottom) {
        if (marginTop == 0 && !isAltBuffer) {
          lines.insert(absoluteMarginBottom + 1, _newEmptyLine());
        } else {
          scrollUp(1);
        }
      } else {
        moveCursorY(1);
      }
      return;
    }

    // the cursor is not in the scrollable region
    if (_cursorY >= viewHeight - 1) {
      // we are at the bottom
      if (isAltBuffer) {
        scrollUp(1);
      } else {
        lines.push(_newEmptyLine());
      }
    } else {
      // there're still lines so we simply move cursor down.
      moveCursorY(1);
    }
  }

  void lineFeed() {
    index();
    if (terminal.lineFeedMode) {
      setCursorX(0);
    }
  }

  /// https://terminalguide.namepad.de/seq/a_esc_cm/
  void reverseIndex() {
    if (isInVerticalMargin) {
      if (_cursorY == _marginTop) {
        scrollDown(1);
      } else {
        moveCursorY(-1);
      }
    } else {
      moveCursorY(-1);
    }
  }

  void cursorGoForward() {
    _cursorX = min(_cursorX + 1, viewWidth);
  }

  void setCursorX(int cursorX) {
    _cursorX = cursorX.clamp(0, viewWidth - 1);
  }

  void setCursorY(int cursorY) {
    _cursorY = cursorY.clamp(0, viewHeight - 1);
  }

  void moveCursorX(int offset) {
    setCursorX(_cursorX + offset);
  }

  void moveCursorY(int offset) {
    setCursorY(_cursorY + offset);
  }

  void setCursor(int cursorX, int cursorY) {
    var maxCursorY = viewHeight - 1;

    if (terminal.originMode) {
      cursorY += _marginTop;
      maxCursorY = _marginBottom;
    }

    _cursorX = cursorX.clamp(0, viewWidth - 1);
    _cursorY = cursorY.clamp(0, maxCursorY);
  }

  void moveCursor(int offsetX, int offsetY) {
    final cursorX = _cursorX + offsetX;
    final cursorY = _cursorY + offsetY;
    setCursor(cursorX, cursorY);
  }

  /// Save cursor position, charmap and text attributes.
  void saveCursor() {
    _savedCursorX = _cursorX;
    _savedCursorY = _cursorY;
    _savedCursorStyle.foreground = terminal.cursor.foreground;
    _savedCursorStyle.background = terminal.cursor.background;
    _savedCursorStyle.attrs = terminal.cursor.attrs;
    charset.save();
  }

  /// Restore cursor position, charmap and text attributes.
  void restoreCursor() {
    _cursorX = _savedCursorX;
    _cursorY = _savedCursorY;
    terminal.cursor.foreground = _savedCursorStyle.foreground;
    terminal.cursor.background = _savedCursorStyle.background;
    terminal.cursor.attrs = _savedCursorStyle.attrs;
    charset.restore();
  }

  /// Sets the vertical scrolling margin to [top] and [bottom].
  /// Both values must be between 0 and [viewHeight] - 1.
  void setVerticalMargins(int top, int bottom) {
    _marginTop = top.clamp(0, viewHeight - 1);
    _marginBottom = bottom.clamp(0, viewHeight - 1);

    _marginTop = min(_marginTop, _marginBottom);
    _marginBottom = max(_marginTop, _marginBottom);
  }

  bool get isInVerticalMargin {
    return _cursorY >= _marginTop && _cursorY <= _marginBottom;
  }

  void resetVerticalMargins() {
    setVerticalMargins(0, viewHeight - 1);
  }

  void deleteChars(int count) {
    final start = _cursorX.clamp(0, viewWidth);
    count = min(count, viewWidth - start);
    currentLine.removeCells(start, count, terminal.cursor);
  }

  /// Remove all lines above the top of the viewport.
  void clearScrollback() {
    if (height <= viewHeight) {
      return;
    }

    lines.trimStart(scrollBack);
  }

  /// Clears the viewport and scrollback buffer. Then fill with empty lines.
  void clear() {
    lines.clear();
    for (int i = 0; i < viewHeight; i++) {
      lines.push(_newEmptyLine());
    }
  }

  void insertBlankChars(int count) {
    currentLine.insertCells(_cursorX, count, terminal.cursor);
  }

  void insertLines(int count) {
    if (!isInVerticalMargin) {
      return;
    }

    setCursorX(0);

    // Cache computed positions before mutations.
    final absBottom = absoluteMarginBottom;
    final absCursor = absoluteCursorY;
    final linesToInsert = min(count, absBottom - absCursor + 1);

    // Remove lines from bottom of scroll region, insert blanks at cursor.
    // This shifts lines down without creating duplicate references.
    for (var i = 0; i < linesToInsert; i++) {
      lines.remove(absBottom);
      lines.insert(absCursor, _newEmptyLine());
    }
  }

  /// Remove [count] lines starting at the current cursor position. Lines below
  /// the removed lines are shifted up. This only affects the scrollable region.
  /// Lines outside the scrollable region are not affected.
  void deleteLines(int count) {
    if (!isInVerticalMargin) {
      return;
    }

    setCursorX(0);

    // Cache computed positions before mutations.
    final absBottom = absoluteMarginBottom;
    final absCursor = absoluteCursorY;
    count = min(count, absBottom - absCursor + 1);

    // Remove lines at cursor, insert blanks at bottom of scroll region.
    // This shifts lines up without creating duplicate references.
    for (var i = 0; i < count; i++) {
      lines.remove(absCursor);
      lines.insert(absBottom, _newEmptyLine());
    }
  }

  void resize(int oldWidth, int oldHeight, int newWidth, int newHeight) {
    final debug = terminal.debugConfig;
    if (debug.logBufferOperations) {
      debug.onLog?.call('debug', 'buffer',
          'resize(${oldWidth}x$oldHeight -> ${newWidth}x$newHeight) '
          'lines=${lines.length} cursorY=$_cursorY');
    }

    final needsReflow =
        newWidth != oldWidth && terminal.reflowEnabled && !isAltBuffer;

    if (needsReflow) {
      // When reflow is needed, do width adjustment FIRST, then height.
      // This ensures the cursor position is correctly calculated after
      // the buffer content changes due to reflow.

      // Track the cursor's absolute position in the buffer before reflow.
      // This lets us find where the cursor ends up after lines are
      // rearranged.
      final cursorAbsY = absoluteCursorY;
      final cursorAnchor = createAnchor(_cursorX, cursorAbsY);

      final reflowResult = reflow(lines, oldWidth, newWidth);

      while (reflowResult.length < newHeight) {
        reflowResult.add(_newEmptyLine(newWidth));
      }

      lines.replaceWith(reflowResult);

      // Recalculate cursor position after reflow. At this point,
      // viewHeight is still oldHeight (terminal hasn't updated yet),
      // so we compute scrollback using oldHeight explicitly.
      final newScrollBack = max(lines.length - oldHeight, 0);

      if (cursorAnchor.attached) {
        // The anchor survived reflow and buffer replacement — use its
        // tracked position to restore the cursor.
        _cursorX = cursorAnchor.x.clamp(0, newWidth - 1);
        _cursorY = (cursorAnchor.y - newScrollBack).clamp(0, oldHeight - 1);
        cursorAnchor.dispose();
      } else {
        // The anchor's line was trimmed during replaceWith. Place the
        // cursor at the top of the viewport.
        _cursorX = _cursorX.clamp(0, newWidth - 1);
        _cursorY = 0;
      }

      // Now adjust the height.
      if (newHeight > oldHeight) {
        for (var i = 0; i < newHeight - oldHeight; i++) {
          if (newHeight > lines.length) {
            lines.push(_newEmptyLine(newWidth));
          } else {
            _cursorY++;
          }
        }
      } else {
        for (var i = 0; i < oldHeight - newHeight; i++) {
          if (_cursorY > newHeight - 1) {
            _cursorY--;
          } else {
            lines.pop();
          }
        }
      }

      // Final clamp.
      _cursorX = _cursorX.clamp(0, newWidth - 1);
      _cursorY = _cursorY.clamp(0, newHeight - 1);
    } else {
      // No reflow needed — adjust height first, then width.

      // 1. Adjust the height.
      if (newHeight > oldHeight) {
        for (var i = 0; i < newHeight - oldHeight; i++) {
          if (newHeight > lines.length) {
            lines.push(_newEmptyLine(newWidth));
          } else {
            _cursorY++;
          }
        }
      } else {
        for (var i = 0; i < oldHeight - newHeight; i++) {
          if (_cursorY > newHeight - 1) {
            _cursorY--;
          } else {
            lines.pop();
          }
        }
      }

      // Ensure cursor is within the screen.
      _cursorX = _cursorX.clamp(0, newWidth - 1);
      _cursorY = _cursorY.clamp(0, newHeight - 1);

      // 2. Adjust the width (no reflow, just resize each line).
      if (newWidth != oldWidth) {
        lines.forEach((item) => item.resize(newWidth));
      }
    }

    if (debug.logBufferOperations) {
      debug.onLog?.call('debug', 'buffer',
          'resize complete: lines=${lines.length} cursorY=$_cursorY '
          'scrollBack=$scrollBack');
    }

    assert(() {
      _verifyBufferIntegrity('resize', expectedViewHeight: newHeight);
      return true;
    }());
  }

  /// Create a new [CellAnchor] at the specified [x] and [y] coordinates.
  CellAnchor createAnchor(int x, int y) {
    return lines[y].createAnchor(x);
  }

  /// Create a new [CellAnchor] at the specified [x] and [y] coordinates.
  CellAnchor createAnchorFromOffset(CellOffset offset) {
    return lines[offset.y].createAnchor(offset.x);
  }

  CellAnchor createAnchorFromCursor() {
    return createAnchor(cursorX, absoluteCursorY);
  }

  /// Create a new empty [BufferLine] with the current [viewWidth] if [width]
  /// is not specified.
  BufferLine _newEmptyLine([int? width]) {
    final line = BufferLine(width ?? viewWidth);
    return line;
  }

  static final defaultWordSeparators = <int>{
    0,
    r' '.codeUnitAt(0),
    r'.'.codeUnitAt(0),
    r':'.codeUnitAt(0),
    r'-'.codeUnitAt(0),
    r'\'.codeUnitAt(0),
    r'"'.codeUnitAt(0),
    r'*'.codeUnitAt(0),
    r'+'.codeUnitAt(0),
    r'/'.codeUnitAt(0),
    r'\'.codeUnitAt(0),
  };

  BufferRangeLine? getWordBoundary(CellOffset position) {
    var separators = wordSeparators ?? defaultWordSeparators;
    if (position.y >= lines.length) {
      return null;
    }

    var line = lines[position.y];
    var start = position.x;
    var end = position.x;

    do {
      if (start == 0) {
        break;
      }
      final char = line.getCodePoint(start - 1);
      if (separators.contains(char)) {
        break;
      }
      start--;
    } while (true);

    do {
      if (end >= viewWidth) {
        break;
      }
      final char = line.getCodePoint(end);
      if (separators.contains(char)) {
        break;
      }
      end++;
    } while (true);

    if (start == end) {
      return null;
    }

    return BufferRangeLine(
      CellOffset(start, position.y),
      CellOffset(end, position.y),
    );
  }

  /// Get the plain text content of the buffer including the scrollback.
  /// Accepts an optional [range] to get a specific part of the buffer.
  String getText([BufferRange? range]) {
    range ??= BufferRangeLine(
      CellOffset(0, 0),
      CellOffset(viewWidth - 1, height - 1),
    );

    range = range.normalized;

    final builder = StringBuffer();

    for (var segment in range.toSegments()) {
      if (segment.line < 0 || segment.line >= height) {
        continue;
      }
      final line = lines[segment.line];
      if (!(segment.line == range.begin.y ||
          segment.line == 0 ||
          line.isWrapped)) {
        builder.write("\n");
      }
      builder.write(line.getText(segment.start, segment.end));
    }

    return builder.toString();
  }

  /// Returns a debug representation of the buffer.
  @override
  String toString() {
    final builder = StringBuffer();
    final lineNumberLength = lines.length.toString().length;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];

      builder.write('${i.toString().padLeft(lineNumberLength)}: |${lines[i]}|');

      if (line.isWrapped) {
        builder.write(' (⏎)');
      }

      builder.write('\n');
    }

    return builder.toString();
  }

  /// Debug-only: verifies buffer invariants after critical operations.
  /// Silent in release builds (only called inside assert()).
  ///
  /// [expectedViewHeight] can be provided when the terminal's viewHeight
  /// has not yet been updated (e.g., during resize, where buffer.resize
  /// runs before terminal._viewHeight is set).
  void _verifyBufferIntegrity(String operation, {int? expectedViewHeight}) {
    final debug = terminal.debugConfig;
    final checkHeight = expectedViewHeight ?? viewHeight;

    // Verify circular buffer index consistency.
    lines.verifyIntegrity();

    // Verify all lines in the buffer are attached and have valid indices.
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (!line.attached) {
        final msg = '$operation: line at index $i is detached';
        debug.onBufferWarning?.call(operation, msg);
        if (debug.logBufferOperations) {
          debug.onLog?.call('error', 'buffer', msg);
        }
        assert(false, msg);
      }
    }

    // Verify line count is at least the expected view height.
    if (lines.length < checkHeight) {
      final msg =
          '$operation: line count (${lines.length}) < viewHeight ($checkHeight)';
      debug.onBufferWarning?.call(operation, msg);
      if (debug.logBufferOperations) {
        debug.onLog?.call('error', 'buffer', msg);
      }
      assert(false, msg);
    }
  }
}
