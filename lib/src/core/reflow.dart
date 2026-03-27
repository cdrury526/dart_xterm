import 'dart:math' show min;

import 'package:dart_xterm/src/core/buffer/line.dart';
import 'package:dart_xterm/src/utils/circular_buffer.dart';

class _LineBuilder {
  _LineBuilder([this._capacity = 80]) {
    _result = BufferLine(_capacity);
  }

  final int _capacity;

  late BufferLine _result;

  int _length = 0;

  int get length => _length;

  bool get isEmpty => _length == 0;

  bool get isNotEmpty => _length != 0;

  /// Adds a range of cells from [src] to the builder. Anchors within the range
  /// will be reparented to the new line returned by [take].
  void add(BufferLine src, int start, int length) {
    _result.copyFrom(src, start, _length, length);
    _length += length;
  }

  /// Reuses the given [line] as the initial buffer for this builder.
  void setBuffer(BufferLine line, int length) {
    _result = line;
    _length = length;
  }

  void addAnchor(CellAnchor anchor, int offset) {
    anchor.reparent(_result, _length + offset);
  }

  BufferLine take({required bool wrapped}) {
    final result = _result;
    result.isWrapped = wrapped;
    // result.resize(_length);

    _result = BufferLine(_capacity);
    _length = 0;

    return result;
  }
}

/// Holds a the state of reflow operation of a single logical line.
class _LineReflow {
  final int oldWidth;

  final int newWidth;

  _LineReflow(this.oldWidth, this.newWidth);

  final _lines = <BufferLine>[];

  late final _builder = _LineBuilder(newWidth);

  /// Adds a line to the reflow operation. This method will try to reuse the
  /// given line if possible.
  void add(BufferLine line) {
    final trimmedLength = line.getTrimmedLength(oldWidth);

    // A fast path for empty lines
    if (trimmedLength == 0) {
      _lines.add(line);
      return;
    }

    // We already have some content in the buffer, so we copy the content into
    // the builder instead of reusing the line.
    if (_lines.isNotEmpty || _builder.isNotEmpty) {
      _addPart(line, from: 0, to: trimmedLength);
      return;
    }

    if (newWidth >= oldWidth) {
      // Reuse the line to avoid copying the content and object allocation.
      _builder.setBuffer(line, trimmedLength);
    } else {
      _lines.add(line);

      if (trimmedLength > newWidth) {
        if (line.getWidth(newWidth - 1) == 2) {
          _addPart(line, from: newWidth - 1, to: trimmedLength);
        } else {
          _addPart(line, from: newWidth, to: trimmedLength);
        }
      }
    }

    line.resize(newWidth);

    if (line.getWidth(newWidth - 1) == 2) {
      line.resetCell(newWidth - 1);
    }
  }

  /// Adds part of [line] from [from] to [to] to the reflow operation.
  /// Anchors within the range will be removed from [line] and reparented to
  /// the new line(s) returned by [finish].
  void _addPart(BufferLine line, {required int from, required int to}) {
    var cellsLeft = to - from;

    while (cellsLeft > 0) {
      final bufferRemainingCells = newWidth - _builder.length;

      // How many cells we should copy in this iteration.
      var cellsToCopy = cellsLeft;

      // Whether the buffer is filled up in this iteration.
      var lineFilled = false;

      if (cellsToCopy >= bufferRemainingCells) {
        cellsToCopy = bufferRemainingCells;
        lineFilled = true;
      }

      // Leave the last cell to the next iteration if it's a wide char.
      if (lineFilled && line.getWidth(from + cellsToCopy - 1) == 2) {
        cellsToCopy--;
      }

      for (var anchor in line.anchors.toList()) {
        if (anchor.x >= from && anchor.x <= from + cellsToCopy) {
          _builder.addAnchor(anchor, anchor.x - from);
        }
      }

      _builder.add(line, from, cellsToCopy);

      from += cellsToCopy;
      cellsLeft -= cellsToCopy;

      // Create a new line if the buffer is filled up.
      if (lineFilled) {
        _lines.add(_builder.take(wrapped: _lines.isNotEmpty));
      }
    }

    if (line.anchors.isNotEmpty) {
      for (var anchor in line.anchors.toList()) {
        if (anchor.x >= to) {
          _builder.addAnchor(anchor, anchor.x - to);
        }
      }
    }
  }

  /// Finalizes the reflow operation and returns the result.
  List<BufferLine> finish() {
    if (_builder.isNotEmpty) {
      _lines.add(_builder.take(wrapped: _lines.isNotEmpty));
    }

    return _lines;
  }
}

bool _isShrinkProtectedStandaloneLine(BufferLine line, int oldWidth) {
  final trimmedLength = line.getTrimmedLength(oldWidth);
  if (trimmedLength == 0) {
    return false;
  }

  var nonEmptyCells = 0;
  var protectedCells = 0;

  for (var i = 0; i < trimmedLength; i++) {
    final codePoint = line.getCodePoint(i);
    if (codePoint == 0) {
      continue;
    }

    nonEmptyCells++;
    if (_isBoxOrBlockDrawing(codePoint)) {
      protectedCells++;
    }
  }

  if (nonEmptyCells == 0) {
    return false;
  }

  return protectedCells * 2 >= nonEmptyCells;
}

bool _hasLargeInternalGap(BufferLine line, int oldWidth, {int minGap = 8}) {
  final trimmedLength = line.getTrimmedLength(oldWidth);
  if (trimmedLength == 0) {
    return false;
  }

  var inContentRun = false;
  var gapLength = 0;
  var contentRuns = 0;

  for (var i = 0; i < trimmedLength; i++) {
    final hasContent = line.getCodePoint(i) != 0;

    if (hasContent) {
      if (!inContentRun) {
        contentRuns++;
      }
      if (gapLength >= minGap && contentRuns >= 2) {
        return true;
      }
      inContentRun = true;
      gapLength = 0;
      continue;
    }

    if (inContentRun) {
      gapLength++;
    }
    inContentRun = false;
  }

  return false;
}

List<(int start, int end)> _extractContentClusters(
  BufferLine line,
  int oldWidth, {
  int minGap = 8,
}) {
  final trimmedLength = line.getTrimmedLength(oldWidth);
  if (trimmedLength == 0) {
    return const [];
  }

  final clusters = <(int start, int end)>[];
  int? clusterStart;
  var lastContent = -1;
  var gapLength = 0;

  for (var i = 0; i < trimmedLength; i++) {
    final hasContent = line.getCodePoint(i) != 0;

    if (hasContent) {
      if (clusterStart == null) {
        clusterStart = i;
      } else if (gapLength >= minGap) {
        clusters.add((clusterStart, lastContent + 1));
        clusterStart = i;
      }

      lastContent = i;
      gapLength = 0;
      continue;
    }

    if (clusterStart != null) {
      gapLength++;
    }
  }

  if (clusterStart != null && lastContent >= clusterStart) {
    clusters.add((clusterStart, lastContent + 1));
  }

  return clusters;
}

bool _isTrivialLeadingPromptCluster(
  BufferLine line,
  (int start, int end) cluster,
) {
  final (start, end) = cluster;
  final length = end - start;

  if (start != 0 || length <= 0 || length > 2) {
    return false;
  }

  for (var i = start; i < end; i++) {
    final codePoint = line.getCodePoint(i);
    if (!_isPromptFragmentCodePoint(codePoint)) {
      return false;
    }
  }

  return true;
}

bool _isPromptFragmentCodePoint(int codePoint) {
  switch (codePoint) {
    case 0x0025: // %
    case 0x0024: // $
    case 0x0023: // #
    case 0x003E: // >
    case 0x276F: // ❯
    case 0x27A4: // ➤
      return true;
    default:
      return false;
  }
}

List<BufferLine> _wrapCluster(
  BufferLine line,
  int start,
  int end,
  int newWidth,
) {
  final result = <BufferLine>[];
  var offset = start;

  while (offset < end) {
    final chunkEnd = min(offset + newWidth, end);
    final chunkLength = chunkEnd - offset;
    final chunk = BufferLine(newWidth);
    chunk.copyFrom(line, offset, 0, chunkLength);
    chunk.resize(newWidth);
    chunk.isWrapped = result.isNotEmpty;

    if (newWidth > 0 && chunk.getWidth(newWidth - 1) == 2) {
      chunk.resetCell(newWidth - 1);
    }

    result.add(chunk);
    offset = chunkEnd;
  }

  return result;
}

List<BufferLine> _reflowPreservingInternalGaps(
  BufferLine line,
  int oldWidth,
  int newWidth,
) {
  final clusters = _extractContentClusters(line, oldWidth);
  if (clusters.isEmpty) {
    line.resize(newWidth);
    return [line];
  }

  final filteredClusters = [...clusters];
  if (filteredClusters.length > 1 &&
      _isTrivialLeadingPromptCluster(line, filteredClusters.first)) {
    filteredClusters.removeAt(0);
  }

  final result = <BufferLine>[];

  for (final (start, end) in filteredClusters) {
    final wrappedCluster = _wrapCluster(line, start, end, newWidth);
    if (wrappedCluster.isEmpty) {
      continue;
    }

    if (result.isNotEmpty) {
      wrappedCluster.first.isWrapped = false;
    }

    result.addAll(wrappedCluster);
  }

  return result;
}

bool _isBoxOrBlockDrawing(int codePoint) {
  return (codePoint >= 0x2500 && codePoint <= 0x259F) ||
      (codePoint >= 0x2800 && codePoint <= 0x28FF);
}

List<BufferLine> reflow(
  IndexAwareCircularBuffer<BufferLine> lines,
  int oldWidth,
  int newWidth,
) {
  final result = <BufferLine>[];
  final isShrinking = newWidth < oldWidth;

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final nextLine = i + 1 < lines.length ? lines[i + 1] : null;

    // Cursor-positioned TUIs redraw individual screen rows in place. When the
    // viewport narrows, reflowing those standalone rows turns a fixed screen
    // layout into wrapped garbage. Keep standalone rows fixed on shrink and
    // only reflow actual wrapped logical lines.
    if (isShrinking &&
        nextLine?.isWrapped != true &&
        _isShrinkProtectedStandaloneLine(line, oldWidth)) {
      line.resize(newWidth);
      if (newWidth > 0 && line.getWidth(newWidth - 1) == 2) {
        line.resetCell(newWidth - 1);
      }
      result.add(line);
      continue;
    }

    if (isShrinking &&
        nextLine?.isWrapped != true &&
        _hasLargeInternalGap(line, oldWidth)) {
      result.addAll(_reflowPreservingInternalGaps(line, oldWidth, newWidth));
      continue;
    }

    final reflow = _LineReflow(oldWidth, newWidth);

    reflow.add(line);

    for (var offset = i + 1; offset < lines.length; offset++) {
      final nextLine = lines[offset];

      if (!nextLine.isWrapped) {
        break;
      }

      i++;

      reflow.add(nextLine);
    }

    result.addAll(reflow.finish());
  }

  for (var line in result) {
    line.resize(newWidth);
  }

  return result;
}
