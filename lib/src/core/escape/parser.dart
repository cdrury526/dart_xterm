import 'package:dart_xterm/src/core/color.dart';
import 'package:dart_xterm/src/core/mouse/mode.dart';
import 'package:dart_xterm/src/core/escape/handler.dart';
import 'package:dart_xterm/src/utils/ascii.dart';
import 'package:dart_xterm/src/utils/byte_consumer.dart';
import 'package:dart_xterm/src/utils/char_code.dart';
import 'package:dart_xterm/src/utils/lookup_table.dart';

/// [EscapeParser] translates control characters and escape sequences into
/// function calls that the terminal can handle.
///
/// Design goals:
///  * Zero object allocation during processing.
///  * No internal state. Same input will always produce same output.
class EscapeParser {
  final EscapeHandler handler;

  /// Called when a malformed escape sequence is encountered. The [sequence]
  /// contains the raw bytes that could not be parsed, and [reason] explains
  /// why parsing failed. This fires independently of [TerminalDebugConfig].
  void Function(String sequence, String reason)? onParseError;

  /// Called when a valid but unimplemented escape sequence is received. The
  /// [sequence] is a human-readable representation. This fires independently
  /// of [TerminalDebugConfig].
  void Function(String sequence)? onUnhandledSequence;

  EscapeParser(this.handler, {this.onParseError, this.onUnhandledSequence});

  final _queue = ByteConsumer();

  /// Start of sequence or character being processed. Useful for debugging.
  var tokenBegin = 0;

  /// End of sequence or character being processed. Useful for debugging.
  int get tokenEnd => _queue.totalConsumed;

  void write(String chunk) {
    _queue.unrefConsumedBlocks();
    _queue.add(chunk);
    _process();
  }

  void _process() {
    while (_queue.isNotEmpty) {
      tokenBegin = _queue.totalConsumed;
      final char = _queue.consume();

      if (char == Ascii.ESC) {
        final processed = _processEscape();
        if (!processed) {
          _queue.rollback(tokenEnd - tokenBegin);
          return;
        }
      } else {
        _processChar(char);
      }
    }
  }

  void _processChar(int char) {
    if (char > _sbcHandlers.maxIndex) {
      handler.writeChar(char);
      return;
    }

    final sbcHandler = _sbcHandlers[char];
    if (sbcHandler == null) {
      onUnhandledSequence?.call(
          'SBC 0x${char.toRadixString(16)} (${String.fromCharCode(char)})');
      handler.unkownEscape(char);
      return;
    }

    sbcHandler();
  }

  /// Processes a sequence of characters that starts with an escape character.
  /// Returns [true] if the sequence was processed, [false] if it was not.
  bool _processEscape() {
    if (_queue.isEmpty) return false;

    final escapeChar = _queue.consume();
    final escapeHandler = _escHandlers[escapeChar];

    if (escapeHandler == null) {
      onUnhandledSequence?.call(
          'ESC 0x${escapeChar.toRadixString(16)} (${String.fromCharCode(escapeChar)})');
      handler.unkownEscape(escapeChar);
      return true;
    }

    return escapeHandler();
  }

  late final _sbcHandlers = FastLookupTable<_SbcHandler>({
    0x07: handler.bell,
    0x08: handler.backspaceReturn,
    0x09: handler.tab,
    0x0a: handler.lineFeed,
    0x0b: handler.lineFeed,
    0x0c: handler.lineFeed,
    0x0d: handler.carriageReturn,
    0x0e: handler.shiftOut,
    0x0f: handler.shiftIn,
  });

  late final _escHandlers = FastLookupTable<_EscHandler>({
    '['.charCode: _escHandleCSI,
    ']'.charCode: _escHandleOSC,
    '7'.charCode: _escHandleSaveCursor,
    '8'.charCode: _escHandleRestoreCursor,
    'D'.charCode: _escHandleIndex,
    'E'.charCode: _escHandleNextLine,
    'H'.charCode: _escHandleTabSet,
    'M'.charCode: _escHandleReverseIndex,
    'P'.charCode: _escHandleDCS, // DCS — Device Control String (consume & discard)
    // 'c'.charCode: _unsupportedHandler,
    // '#'.charCode: _unsupportedHandler,
    '('.charCode: _escHandleDesignateCharset0, //  SCS - G0
    ')'.charCode: _escHandleDesignateCharset1, //  SCS - G1
    // '*'.charCode: _voidHandler(1), // TODO: G2 (vt220)
    // '+'.charCode: _voidHandler(1), // TODO: G3 (vt220)
    '>'.charCode: _escHandleResetAppKeypadMode, // TODO: Normal Keypad
    '='.charCode: _escHandleSetAppKeypadMode, // TODO: Application Keypad
  });

  /// `ESC P ... ST` — Device Control String (DCS).
  ///
  /// Consumes the DCS content until the string terminator (ESC \ or BEL)
  /// and discards it. Sixel graphics, DECRQSS, and other DCS sequences
  /// are not implemented, but we must consume them to avoid corrupting
  /// the parse state.
  bool _escHandleDCS() {
    while (true) {
      if (_queue.isEmpty) return false;
      final char = _queue.consume();
      // DCS terminates with BEL (some terminals) or ST (ESC \).
      if (char == Ascii.BEL) return true;
      if (char == Ascii.ESC) {
        if (_queue.isEmpty) return false;
        if (_queue.consume() == Ascii.backslash) return true;
        // Not ST — keep consuming.
      }
    }
  }

  /// `ESC 7` Save Cursor (DECSC)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_a7/
  bool _escHandleSaveCursor() {
    handler.saveCursor();
    return true;
  }

  /// `ESC 8` Restore Cursor (DECRC)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_a8/
  bool _escHandleRestoreCursor() {
    handler.restoreCursor();
    return true;
  }

  /// `ESC D` Index (IND)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_cd/
  bool _escHandleIndex() {
    handler.index();
    return true;
  }

  /// `ESC E` Next Line (NEL)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_ce/
  bool _escHandleNextLine() {
    handler.nextLine();
    return true;
  }

  /// `ESC H` Horizontal Tab Set (HTS)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_ch/
  bool _escHandleTabSet() {
    handler.setTapStop();
    return true;
  }

  /// `ESC M` Reverse Index (RI)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_cm/
  bool _escHandleReverseIndex() {
    handler.reverseIndex();
    return true;
  }

  bool _escHandleDesignateCharset0() {
    if (_queue.isEmpty) return false;
    int name = _queue.consume();
    handler.designateCharset(0, name);
    return true;
  }

  bool _escHandleDesignateCharset1() {
    if (_queue.isEmpty) return false;
    int name = _queue.consume();
    handler.designateCharset(1, name);
    return true;
  }

  /// `ESC >` Reset Application Keypad Mode (DECKPNM)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_x3c_greater_than/
  bool _escHandleSetAppKeypadMode() {
    handler.setAppKeypadMode(true);
    return true;
  }

  /// `ESC =` Set Application Keypad Mode (DECKPAM)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_x3d_equals/
  bool _escHandleResetAppKeypadMode() {
    handler.setAppKeypadMode(false);
    return true;
  }

  bool _escHandleCSI() {
    final consumed = _consumeCsi();
    if (!consumed) return false;

    final csiHandler = _csiHandlers[_csi.finalByte];

    if (csiHandler == null) {
      onUnhandledSequence?.call(
          'CSI ${_csi.prefix != null ? "${String.fromCharCode(_csi.prefix!)} " : ""}'
          '${_csi.params.join(";")} ${String.fromCharCode(_csi.finalByte)}');
      handler.unknownCSI(_csi.finalByte);
    } else {
      csiHandler();
    }

    return true;
  }

  /// The last parsed [_Csi]. This is a mutable singletion by design to reduce
  /// object allocations.
  final _csi = _Csi(finalByte: 0, params: []);

  /// Parse a CSI from the head of the queue. Return false if the CSI isn't
  /// complete. After a CSI is successfully parsed, [_csi] is updated.
  bool _consumeCsi() {
    if (_queue.isEmpty) {
      return false;
    }

    _csi.params.clear();
    _csi.subParams.clear();
    _csi.intermediates.clear();

    // test whether the csi is a `CSI ? Ps ...` or `CSI Ps ...`
    final prefix = _queue.peek();
    if (prefix >= Ascii.colon && prefix <= Ascii.questionMark) {
      _csi.prefix = prefix;
      _queue.consume();
    } else {
      _csi.prefix = null;
    }

    var param = 0;
    var hasParam = false;
    // Track colon-separated sub-parameters for the current param.
    var inSubParam = false;
    var subParam = 0;
    List<int>? currentSubParams;

    while (true) {
      // The sequence isn't completed, just ignore it.
      if (_queue.isEmpty) {
        return false;
      }

      final char = _queue.consume();

      if (char == Ascii.semicolon) {
        if (inSubParam && currentSubParams != null) {
          currentSubParams.add(subParam);
          // Index at length-1 because the main param was already added
          // when the first colon was encountered.
          _csi.subParams[_csi.params.length - 1] = currentSubParams;
          inSubParam = false;
          currentSubParams = null;
        }
        if (hasParam) {
          _csi.params.add(param);
        }
        param = 0;
        hasParam = false;
        subParam = 0;
        continue;
      }

      // Colon separates sub-parameters (e.g., CSI 4:3m for curly underline,
      // CSI 38:2:R:G:Bm for RGB colors). Save the main param and start
      // accumulating sub-parameters.
      if (char == Ascii.colon) {
        if (!inSubParam) {
          // First colon — save the main param, start sub-param collection
          if (hasParam) {
            _csi.params.add(param);
          }
          param = 0;
          hasParam = false;
          inSubParam = true;
          currentSubParams = [];
          subParam = 0;
        } else {
          // Additional colon — save current sub-param, start next
          currentSubParams!.add(subParam);
          subParam = 0;
        }
        continue;
      }

      if (char >= Ascii.num0 && char <= Ascii.num9) {
        hasParam = true;
        if (inSubParam) {
          subParam *= 10;
          subParam += char - Ascii.num0;
        } else {
          param *= 10;
          param += char - Ascii.num0;
        }
        continue;
      }

      // Intermediate bytes (0x20-0x2F) — e.g. '$' (0x24) in DECRQM.
      // Bytes in range 0x01-0x1F are C0 controls embedded in the sequence
      // (ignored per VT spec). Bytes 0x20-0x2F are intermediates.
      if (char > Ascii.NULL && char < Ascii.num0) {
        if (char >= 0x20 && char <= 0x2F) {
          _csi.intermediates.add(char);
        }
        continue;
      }

      if (char >= Ascii.atSign && char <= Ascii.tilde) {
        if (inSubParam && currentSubParams != null) {
          currentSubParams.add(subParam);
          // Index at length-1 because the main param was already added
          // when the first colon was encountered.
          _csi.subParams[_csi.params.length - 1] = currentSubParams;
        }
        if (hasParam) {
          _csi.params.add(param);
        }

        _csi.finalByte = char;
        return true;
      }
    }
  }

  late final _csiHandlers = FastLookupTable<_CsiHandler>({
    // 'a'.codeUnitAt(0): _csiHandleCursorHorizontalRelative,
    'b'.codeUnitAt(0): _csiHandleRepeatPreviousCharacter,
    'c'.codeUnitAt(0): _csiHandleSendDeviceAttributes,
    'd'.codeUnitAt(0): _csiHandleLinePositionAbsolute,
    'f'.codeUnitAt(0): _csiHandleCursorPosition,
    'g'.codeUnitAt(0): _csiHandelClearTabStop,
    'h'.codeUnitAt(0): _csiHandleMode,
    'l'.codeUnitAt(0): _csiHandleMode,
    'm'.codeUnitAt(0): _csiHandleSgr,
    'n'.codeUnitAt(0): _csiHandleDeviceStatusReport,
    'p'.codeUnitAt(0): _csiHandleRequestMode,
    'q'.codeUnitAt(0): _csiHandleXtVersion,
    'r'.codeUnitAt(0): _csiHandleSetMargins,
    't'.codeUnitAt(0): _csiWindowManipulation,
    'u'.codeUnitAt(0): _csiHandleKittyKeyboard,
    'A'.codeUnitAt(0): _csiHandleCursorUp,
    'B'.codeUnitAt(0): _csiHandleCursorDown,
    'C'.codeUnitAt(0): _csiHandleCursorForward,
    'D'.codeUnitAt(0): _csiHandleCursorBackward,
    'E'.codeUnitAt(0): _csiHandleCursorNextLine,
    'F'.codeUnitAt(0): _csiHandleCursorPrecedingLine,
    'G'.codeUnitAt(0): _csiHandleCursorHorizontalAbsolute,
    'H'.codeUnitAt(0): _csiHandleCursorPosition,
    'J'.codeUnitAt(0): _csiHandleEraseDisplay,
    'K'.codeUnitAt(0): _csiHandleEraseLine,
    'L'.codeUnitAt(0): _csiHandleInsertLines,
    'M'.codeUnitAt(0): _csiHandleDeleteLines,
    'P'.codeUnitAt(0): _csiHandleDelete,
    'S'.codeUnitAt(0): _csiHandleScrollUp,
    'T'.codeUnitAt(0): _csiHandleScrollDown,
    'X'.codeUnitAt(0): _csiHandleEraseCharacters,
    '@'.codeUnitAt(0): _csiHandleInsertBlankCharacters,
  });

  /// `ESC [ Ps a` Cursor Horizontal Position Relative (HPR)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sa/
  // void _csiHandleCursorHorizontalRelative() {
  //   if (_csi.params.isEmpty) {
  //     handler.cursorHorizontal(1);
  //   } else {
  //     handler.cursorHorizontal(_csi.params[0]);
  //   }
  // }

  /// `ESC [ Ps b` Repeat Previous Character (REP)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sb/
  void _csiHandleRepeatPreviousCharacter() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.repeatPreviousCharacter(amount);
  }

  /// `ESC [ Ps c` Device Attributes (DA)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sc/
  void _csiHandleSendDeviceAttributes() {
    switch (_csi.prefix) {
      case Ascii.greaterThan:
        return handler.sendSecondaryDeviceAttributes();
      case Ascii.equal:
        return handler.sendTertiaryDeviceAttributes();
      default:
        handler.sendPrimaryDeviceAttributes();
    }
  }

  /// `ESC [ Ps d` Cursor Vertical Position Absolute (VPA)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sd/
  void _csiHandleLinePositionAbsolute() {
    var y = 1;

    if (_csi.params.isNotEmpty) {
      y = _csi.params[0];
    }

    handler.setCursorY(y - 1);
  }

  /// `ESC [ Ps ; Ps f` Alias: Set Cursor Position
  ///
  /// https://terminalguide.namepad.de/seq/csi_sf/
  void _csiHandleCursorPosition() {
    var row = 1;
    var col = 1;

    if (_csi.params.length == 2) {
      row = _csi.params[0];
      col = _csi.params[1];
    }

    handler.setCursor(col - 1, row - 1);
  }

  /// `ESC [ Ps g` Tab Clear (TBC)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sg/
  void _csiHandelClearTabStop() {
    var cmd = 0;

    if (_csi.params.length == 1) {
      cmd = _csi.params[0];
    }

    switch (cmd) {
      case 0:
        return handler.clearTabStopUnderCursor();
      default:
        return handler.clearAllTabStops();
    }
  }

  /// - `ESC [ [ Pm ] h Set Mode (SM)` https://terminalguide.namepad.de/seq/csi_sm/
  /// - `ESC [ ? [ Pm ] h` Set Mode (?) (SM) https://terminalguide.namepad.de/seq/csi_sh__p/
  /// - `ESC [ [ Pm ] l` Reset Mode (RM) https://terminalguide.namepad.de/seq/csi_rm/
  /// - `ESC [ ? [ Pm ] l` Reset Mode (?) (RM) https://terminalguide.namepad.de/seq/csi_sl__p/
  void _csiHandleMode() {
    final isEnabled = _csi.finalByte == Ascii.h;

    final isDecModes = _csi.prefix == Ascii.questionMark;

    if (isDecModes) {
      for (var mode in _csi.params) {
        _setDecMode(mode, isEnabled);
      }
    } else {
      for (var mode in _csi.params) {
        _setMode(mode, isEnabled);
      }
    }
  }

  /// `ESC [ [ Ps ] m` Select Graphic Rendition (SGR)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sm/
  void _csiHandleSgr() {
    final params = _csi.params;

    if (params.isEmpty) {
      return handler.resetCursorStyle();
    }

    // This is a workaround for a bug in the analyzer.
    // ignore: dead_code
    for (var i = 0; i < _csi.params.length; i++) {
      final param = params[i];
      switch (param) {
        case 0:
          handler.resetCursorStyle();
          continue;
        case 1:
          handler.setCursorBold();
          continue;
        case 2:
          handler.setCursorFaint();
          continue;
        case 3:
          handler.setCursorItalic();
          continue;
        case 4:
          final subParams4 = _csi.subParams[i];
          if (subParams4 != null && subParams4.isNotEmpty) {
            if (subParams4[0] == 0) {
              handler.unsetCursorUnderline();
            } else {
              handler.setCursorUnderline();
            }
          } else {
            handler.setCursorUnderline();
          }
          continue;
        case 5:
          handler.setCursorBlink();
          continue;
        case 7:
          handler.setCursorInverse();
          continue;
        case 8:
          handler.setCursorInvisible();
          continue;
        case 9:
          handler.setCursorStrikethrough();
          continue;

        case 21:
          handler.unsetCursorBold();
          continue;
        case 22:
          handler.unsetCursorFaint();
          continue;
        case 23:
          handler.unsetCursorItalic();
          continue;
        case 24:
          handler.unsetCursorUnderline();
          continue;
        case 25:
          handler.unsetCursorBlink();
          continue;
        case 27:
          handler.unsetCursorInverse();
          continue;
        case 28:
          handler.unsetCursorInvisible();
          continue;
        case 29:
          handler.unsetCursorStrikethrough();
          continue;

        // SGR 53 — overline on
        case 53:
          handler.setCursorOverline();
          continue;
        // SGR 55 — overline off
        case 55:
          handler.unsetCursorOverline();
          continue;

        // SGR 58 — set underline color (colon-separated: 58:2::R:G:B
        // or 58:5:N; semicolon-separated: 58;2;R;G;B or 58;5;N)
        case 58:
          final subs58 = _csi.subParams[i];
          if (subs58 != null && subs58.isNotEmpty) {
            final mode = subs58[0];
            if (mode == 2 && subs58.length >= 4) {
              // Colon format: 58:2:R:G:B or 58:2::R:G:B
              // Some apps send an extra empty sub-param (the color space ID).
              // If subs58 has 5+ elements, the RGB values start at index 2.
              if (subs58.length >= 5) {
                handler.setUnderlineColorRgb(
                    subs58[2], subs58[3], subs58[4]);
              } else {
                handler.setUnderlineColorRgb(
                    subs58[1], subs58[2], subs58[3]);
              }
            } else if (mode == 5 && subs58.length >= 2) {
              handler.setUnderlineColor256(subs58[1]);
            }
          } else if (i + 1 < params.length) {
            final mode = params[i + 1];
            switch (mode) {
              case 2:
                if (i + 4 < params.length) {
                  handler.setUnderlineColorRgb(
                      params[i + 2], params[i + 3], params[i + 4]);
                  i += 4;
                }
                break;
              case 5:
                if (i + 2 < params.length) {
                  handler.setUnderlineColor256(params[i + 2]);
                  i += 2;
                }
                break;
            }
          }
          continue;

        // SGR 59 — reset underline color to default
        case 59:
          handler.resetUnderlineColor();
          continue;

        case 30:
          handler.setForegroundColor16(NamedColor.black);
          continue;
        case 31:
          handler.setForegroundColor16(NamedColor.red);
          continue;
        case 32:
          handler.setForegroundColor16(NamedColor.green);
          continue;
        case 33:
          handler.setForegroundColor16(NamedColor.yellow);
          continue;
        case 34:
          handler.setForegroundColor16(NamedColor.blue);
          continue;
        case 35:
          handler.setForegroundColor16(NamedColor.magenta);
          continue;
        case 36:
          handler.setForegroundColor16(NamedColor.cyan);
          continue;
        case 37:
          handler.setForegroundColor16(NamedColor.white);
          continue;
        case 38:
          // Handle colon-separated sub-params: 38:2:R:G:B, 38:2::R:G:B,
          // 38:2:CS:R:G:B, or 38:5:N
          final subs38 = _csi.subParams[i];
          if (subs38 != null && subs38.isNotEmpty) {
            final mode = subs38[0];
            if (mode == 2 && subs38.length >= 4) {
              // 38:2:CS:R:G:B (5+ sub-params) or 38:2:R:G:B (4 sub-params).
              // When there are 5+ sub-params, the color space ID is at [1]
              // and RGB starts at [2]. When exactly 4, RGB is at [1..3].
              if (subs38.length >= 5) {
                handler.setForegroundColorRgb(
                    subs38[2], subs38[3], subs38[4]);
              } else {
                handler.setForegroundColorRgb(
                    subs38[1], subs38[2], subs38[3]);
              }
            } else if (mode == 5 && subs38.length >= 2) {
              handler.setForegroundColor256(subs38[1]);
            }
          } else if (i + 1 < params.length) {
            // Semicolon-separated: 38;2;R;G;B or 38;5;N
            final mode = params[i + 1];
            switch (mode) {
              case 2:
                if (i + 4 < params.length) {
                  final r = params[i + 2];
                  final g = params[i + 3];
                  final b = params[i + 4];
                  handler.setForegroundColorRgb(r, g, b);
                  i += 4;
                }
                break;
              case 5:
                if (i + 2 < params.length) {
                  final index = params[i + 2];
                  handler.setForegroundColor256(index);
                  i += 2;
                }
                break;
            }
          }
          continue;
        case 39:
          handler.resetForeground();
          continue;

        case 40:
          handler.setBackgroundColor16(NamedColor.black);
          continue;
        case 41:
          handler.setBackgroundColor16(NamedColor.red);
          continue;
        case 42:
          handler.setBackgroundColor16(NamedColor.green);
          continue;
        case 43:
          handler.setBackgroundColor16(NamedColor.yellow);
          continue;
        case 44:
          handler.setBackgroundColor16(NamedColor.blue);
          continue;
        case 45:
          handler.setBackgroundColor16(NamedColor.magenta);
          continue;
        case 46:
          handler.setBackgroundColor16(NamedColor.cyan);
          continue;
        case 47:
          handler.setBackgroundColor16(NamedColor.white);
          continue;
        case 48:
          // Handle colon-separated sub-params: 48:2:R:G:B, 48:2::R:G:B,
          // 48:2:CS:R:G:B, or 48:5:N
          final subs48 = _csi.subParams[i];
          if (subs48 != null && subs48.isNotEmpty) {
            final mode = subs48[0];
            if (mode == 2 && subs48.length >= 4) {
              // Same color space ID handling as SGR 38.
              if (subs48.length >= 5) {
                handler.setBackgroundColorRgb(
                    subs48[2], subs48[3], subs48[4]);
              } else {
                handler.setBackgroundColorRgb(
                    subs48[1], subs48[2], subs48[3]);
              }
            } else if (mode == 5 && subs48.length >= 2) {
              handler.setBackgroundColor256(subs48[1]);
            }
          } else if (i + 1 < params.length) {
            final mode = params[i + 1];
            switch (mode) {
              case 2:
                if (i + 4 < params.length) {
                  final r = params[i + 2];
                  final g = params[i + 3];
                  final b = params[i + 4];
                  handler.setBackgroundColorRgb(r, g, b);
                  i += 4;
                }
                break;
              case 5:
                if (i + 2 < params.length) {
                  final index = params[i + 2];
                  handler.setBackgroundColor256(index);
                  i += 2;
                }
                break;
            }
          }
          continue;
        case 49:
          handler.resetBackground();
          continue;

        case 90:
          handler.setForegroundColor16(NamedColor.brightBlack);
          continue;
        case 91:
          handler.setForegroundColor16(NamedColor.brightRed);
          continue;
        case 92:
          handler.setForegroundColor16(NamedColor.brightGreen);
          continue;
        case 93:
          handler.setForegroundColor16(NamedColor.brightYellow);
          continue;
        case 94:
          handler.setForegroundColor16(NamedColor.brightBlue);
          continue;
        case 95:
          handler.setForegroundColor16(NamedColor.brightMagenta);
          continue;
        case 96:
          handler.setForegroundColor16(NamedColor.brightCyan);
          continue;
        case 97:
          handler.setForegroundColor16(NamedColor.brightWhite);
          continue;

        case 100:
          handler.setBackgroundColor16(NamedColor.brightBlack);
          continue;
        case 101:
          handler.setBackgroundColor16(NamedColor.brightRed);
          continue;
        case 102:
          handler.setBackgroundColor16(NamedColor.brightGreen);
          continue;
        case 103:
          handler.setBackgroundColor16(NamedColor.brightYellow);
          continue;
        case 104:
          handler.setBackgroundColor16(NamedColor.brightBlue);
          continue;
        case 105:
          handler.setBackgroundColor16(NamedColor.brightMagenta);
          continue;
        case 106:
          handler.setBackgroundColor16(NamedColor.brightCyan);
          continue;
        case 107:
          handler.setBackgroundColor16(NamedColor.brightWhite);
          continue;

        default:
          handler.unsupportedStyle(param);
          continue;
      }
    }
  }

  /// `ESC [ Ps n` Device Status Report [Dispatch] (DSR)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sn/
  void _csiHandleDeviceStatusReport() {
    if (_csi.params.isEmpty) return;

    switch (_csi.params[0]) {
      case 5:
        return handler.sendOperatingStatus();
      case 6:
        return handler.sendCursorPosition();
    }
  }

  /// `ESC [ > Ps q` XTVERSION — Report terminal name and version.
  ///
  /// Response: `DCS > | name(version) ST`
  /// Only handled when prefix is `>`. Other prefixes are ignored.
  void _csiHandleXtVersion() {
    if (_csi.prefix != Ascii.greaterThan) return;

    // Ps must be 0 or omitted.
    if (_csi.params.isNotEmpty && _csi.params[0] > 0) return;

    handler.sendXtVersion();
  }

  /// `ESC [ ? Ps $ p` DECRQM (DEC private) — Request DEC private mode.
  /// `ESC [ Ps $ p` DECRQM (ANSI) — Request ANSI mode.
  ///
  /// The intermediate byte `$` (0x24) distinguishes this from other `p`
  /// final-byte sequences. Without `$`, the `p` is ignored.
  ///
  /// Response: `CSI [?] Ps ; Pm $ y` where Pm is the mode status:
  ///   0 = not recognized, 1 = set, 2 = reset,
  ///   3 = permanently set, 4 = permanently reset
  void _csiHandleRequestMode() {
    // DECRQM requires `$` as an intermediate byte.
    if (_csi.intermediates.isEmpty ||
        _csi.intermediates[0] != 0x24 /* $ */) {
      return;
    }

    if (_csi.params.isEmpty) return;

    final mode = _csi.params[0];
    final isDec = _csi.prefix == Ascii.questionMark;
    handler.requestMode(mode, isDec: isDec);
  }

  /// Kitty keyboard protocol handler.
  ///
  /// - `CSI > Ps u` — Push keyboard mode (set flags).
  /// - `CSI < Ps u` — Pop keyboard mode.
  /// - `CSI ? u` — Query current keyboard mode (response: CSI ? flags u).
  ///
  /// action: 1 = push (prefix >), 2 = pop (prefix <), 3 = query (prefix ?)
  void _csiHandleKittyKeyboard() {
    final flags = _csi.params.isNotEmpty ? _csi.params[0] : 0;
    int action;
    switch (_csi.prefix) {
      case Ascii.greaterThan:
        action = 1; // push
        break;
      case Ascii.lessThan:
        action = 2; // pop
        break;
      case Ascii.questionMark:
        action = 3; // query
        break;
      default:
        // Plain CSI Ps u — this could be a kitty fixterms key report.
        // Silently ignore for now.
        return;
    }
    handler.kittyKeyboardMode(flags: flags, action: action);
  }

  /// `ESC [ Ps ; Ps r` Set Top and Bottom Margins (DECSTBM)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sr/
  void _csiHandleSetMargins() {
    var top = 1;
    int? bottom;

    if (_csi.params.length > 2) return;

    if (_csi.params.isNotEmpty) {
      top = _csi.params[0];

      if (_csi.params.length == 2) {
        bottom = _csi.params[1] - 1;
      }
    }

    handler.setMargins(top - 1, bottom);
  }

  /// `ESC [ Ps t` Window operations [DISPATCH]
  ///
  /// https://terminalguide.namepad.de/seq/csi_st/
  void _csiWindowManipulation() {
    // The sequence needs at least one parameter.
    if (_csi.params.isEmpty) {
      return;
    }
    // Most the commands in this group are either of the scope of this package,
    // or should be disabled for security risks.
    switch (_csi.params.first) {
      // Window handling is currently not in the scope of the package.
      case 1: // Restore Terminal Window (show window if minimized)
      case 2: // Minimize Terminal Window
      case 3: // Set Terminal Window Position
      case 4: // Set Terminal Window Size in Pixels
      case 5: // Raise Terminal Window
      case 6: // Lower Terminal Window
      case 7: // Refresh/Redraw Terminal Window
        return;
      case 8: // Set Terminal Window Size (in characters)
        // This CSI contains 2 more parameters: width and height.
        if (_csi.params.length != 3) {
          return;
        }
        final rows = _csi.params[1];
        final cols = _csi.params[2];
        handler.resize(cols, rows);
        return;
      // Window handling is currently no in the scope of the package.
      case 9: // Maximize Terminal Window
      case 10: // Alias: Maximize Terminal Window
      case 11: // Report Terminal Window State
      case 13: // Report Terminal Window Position
      case 14: // Report Terminal Window Size in Pixels
      case 15: // Report Screen Size in Pixels
      case 16: // Report Cell Size in Pixels
        return;
      case 18: // Report Terminal Size (in characters)
        handler.sendSize();
        return;
      // Screen handling is currently no in the scope of the package.
      case 19: // Report Screen Size (in characters)
      // Disabled as these can a security risk.
      case 20: // Get Icon Title
      case 21: // Get Terminal Title
      // Not implemented.
      case 22: // Push Terminal Title
      case 23: // Pop Terminal Title
        return;
      // Unknown CSI.
      default:
        return;
    }
  }

  /// `ESC [ Ps A` Cursor Up (CUU)
  ///
  /// https://terminalguide.namepad.de/seq/csi_ca/
  void _csiHandleCursorUp() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.moveCursorY(-amount);
  }

  /// `ESC [ Ps B` Cursor Down (CUD)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cb/
  void _csiHandleCursorDown() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.moveCursorY(amount);
  }

  /// `ESC [ Ps C` Cursor Right (CUF)
  ///
  /// Cursor Right (CUF)
  void _csiHandleCursorForward() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.moveCursorX(amount);
  }

  /// `ESC [ Ps D` Cursor Left (CUB)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cd/
  void _csiHandleCursorBackward() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.moveCursorX(-amount);
  }

  /// `ESC [ Ps E` Cursor Next Line (CNL)
  ///
  /// https://terminalguide.namepad.de/seq/csi_ce/
  void _csiHandleCursorNextLine() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.cursorNextLine(amount);
  }

  /// `ESC [ Ps F` Cursor Previous Line (CPL)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cf/
  void _csiHandleCursorPrecedingLine() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.cursorPrecedingLine(amount);
  }

  void _csiHandleCursorHorizontalAbsolute() {
    var x = 1;

    if (_csi.params.isNotEmpty) {
      x = _csi.params[0];
      if (x == 0) x = 1;
    }

    handler.setCursorX(x - 1);
  }

  /// ESC [ Ps J Erase Display [Dispatch] (ED)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cj/
  void _csiHandleEraseDisplay() {
    var cmd = 0;

    if (_csi.params.length == 1) {
      cmd = _csi.params[0];
    }

    switch (cmd) {
      case 0:
        return handler.eraseDisplayBelow();
      case 1:
        return handler.eraseDisplayAbove();
      case 2:
        return handler.eraseDisplay();
      case 3:
        return handler.eraseScrollbackOnly();
    }
  }

  /// `ESC [ Ps K` Erase Line [Dispatch] (EL)
  ///
  /// https://terminalguide.namepad.de/seq/csi_ck/
  void _csiHandleEraseLine() {
    var cmd = 0;

    if (_csi.params.length == 1) {
      cmd = _csi.params[0];
    }

    switch (cmd) {
      case 0:
        return handler.eraseLineRight();
      case 1:
        return handler.eraseLineLeft();
      case 2:
        return handler.eraseLine();
    }
  }

  /// `ESC [ Ps L` Insert Line (IL)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cl/
  void _csiHandleInsertLines() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.insertLines(amount);
  }

  /// ESC [ Ps M Delete Line (DL)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cm/
  void _csiHandleDeleteLines() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.deleteLines(amount);
  }

  /// ESC [ Ps P Delete Character (DCH)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cp/
  void _csiHandleDelete() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.deleteChars(amount);
  }

  /// `ESC [ Ps S` Scroll Up (SU)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cs/
  void _csiHandleScrollUp() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.scrollUp(amount);
  }

  /// `ESC [ Ps T `Scroll Down (SD)
  ///
  /// https://terminalguide.namepad.de/seq/csi_ct_1param/
  void _csiHandleScrollDown() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.scrollDown(amount);
  }

  /// `ESC [ Ps X` Erase Character (ECH)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cx/
  void _csiHandleEraseCharacters() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.eraseChars(amount);
  }

  /// `ESC [ Ps @` Insert Blanks (ICH)
  ///
  /// https://terminalguide.namepad.de/seq/csi_x40_at/
  ///
  /// Inserts amount spaces at current cursor position moving existing cell
  /// contents to the right. The contents of the amount right-most columns in
  /// the scroll region are lost. The cursor position is not changed.
  void _csiHandleInsertBlankCharacters() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.insertBlankChars(amount);
  }

  void _setMode(int mode, bool enabled) {
    switch (mode) {
      case 4:
        return handler.setInsertMode(enabled);
      case 20:
        return handler.setLineFeedMode(enabled);
      default:
        return handler.setUnknownMode(mode, enabled);
    }
  }

  void _setDecMode(int mode, bool enabled) {
    switch (mode) {
      case 1:
        return handler.setCursorKeysMode(enabled);
      case 3:
        return handler.setColumnMode(enabled);
      case 5:
        return handler.setReverseDisplayMode(enabled);
      case 6:
        return handler.setOriginMode(enabled);
      case 7:
        return handler.setAutoWrapMode(enabled);
      case 9:
        return enabled
            ? handler.setMouseMode(MouseMode.clickOnly)
            : handler.setMouseMode(MouseMode.none);
      case 12:
      case 13:
        return handler.setCursorBlinkMode(enabled);
      case 25:
        return handler.setCursorVisibleMode(enabled);
      case 47:
        if (enabled) {
          return handler.useAltBuffer();
        } else {
          return handler.useMainBuffer();
        }
      case 66:
        return handler.setAppKeypadMode(enabled);
      case 1000:
      case 10061000:
        return enabled
            ? handler.setMouseMode(MouseMode.upDownScroll)
            : handler.setMouseMode(MouseMode.none);
      case 1001:
        return enabled
            ? handler.setMouseMode(MouseMode.upDownScroll)
            : handler.setMouseMode(MouseMode.none);
      case 1002:
        return enabled
            ? handler.setMouseMode(MouseMode.upDownScrollDrag)
            : handler.setMouseMode(MouseMode.none);
      case 1003:
        return enabled
            ? handler.setMouseMode(MouseMode.upDownScrollMove)
            : handler.setMouseMode(MouseMode.none);
      case 1004:
        return handler.setReportFocusMode(enabled);
      case 1005:
        return enabled
            ? handler.setMouseReportMode(MouseReportMode.utf)
            : handler.setMouseReportMode(MouseReportMode.normal);
      case 1006:
        return enabled
            ? handler.setMouseReportMode(MouseReportMode.sgr)
            : handler.setMouseReportMode(MouseReportMode.normal);
      case 1007:
        return handler.setAltBufferMouseScrollMode(enabled);
      case 1015:
        return enabled
            ? handler.setMouseReportMode(MouseReportMode.urxvt)
            : handler.setMouseReportMode(MouseReportMode.normal);
      case 1047:
        if (enabled) {
          handler.useAltBuffer();
        } else {
          handler.clearAltBuffer();
          handler.useMainBuffer();
        }
        return;
      case 1048:
        if (enabled) {
          return handler.saveCursor();
        } else {
          return handler.restoreCursor();
        }
      case 1049:
        if (enabled) {
          handler.saveCursor();
          handler.clearAltBuffer();
          handler.useAltBuffer();
        } else {
          handler.useMainBuffer();
        }
        return;
      case 2004:
        return handler.setBracketedPasteMode(enabled);
      default:
        return handler.setUnknownDecMode(mode, enabled);
    }
  }

  /// Parse a OSC sequence from the queue. Returns true if a sequence was
  /// found and handled.
  bool _escHandleOSC() {
    final consumed = _consumeOsc();
    if (!consumed) {
      return false;
    }

    if (_osc.isEmpty) {
      return true;
    }

    // Common OSCs
    if (_osc.length >= 2) {
      final ps = _osc[0];
      final pt = _osc[1];

      switch (ps) {
        case '0':
          handler.setTitle(pt);
          handler.setIconName(pt);
          return true;
        case '1':
          handler.setIconName(pt);
          return true;
        case '2':
          handler.setTitle(pt);
          return true;
        case '8':
          // OSC 8 — Hyperlinks. Format: OSC 8 ; params ; uri ST
          // params is key=value pairs (e.g. "id=foo"), uri is the target.
          // Empty uri means end of hyperlink.
          final linkParams = _osc.length >= 2 ? _osc[1] : '';
          final uri = _osc.length >= 3 ? _osc[2] : '';
          handler.setHyperlink(uri, params: linkParams);
          return true;
        case '52':
          // OSC 52 — Clipboard access. Format: OSC 52 ; Pc ; Pd ST
          // Pc = clipboard selection target (c, p, s, etc.)
          // Pd = base64-encoded data, or '?' to request contents.
          if (_osc.length >= 3) {
            handler.clipboardAccess(_osc[1], _osc[2]);
          }
          return true;
      }
    }

    // Private extensions
    handler.unknownOSC(_osc[0], _osc.sublist(1));

    return true;
  }

  final _osc = <String>[];

  bool _consumeOsc() {
    _osc.clear();
    final param = StringBuffer();

    while (true) {
      if (_queue.isEmpty) {
        return false;
      }

      final char = _queue.consume();

      // OSC terminates with BEL
      if (char == Ascii.BEL) {
        _osc.add(param.toString());
        return true;
      }

      /// OSC terminates with ST
      if (char == Ascii.ESC) {
        if (_queue.isEmpty) {
          return false;
        }

        if (_queue.consume() == Ascii.backslash) {
          _osc.add(param.toString());
        }

        return true;
      }

      /// Parse next parameter
      if (char == Ascii.semicolon) {
        _osc.add(param.toString());
        param.clear();
        continue;
      }

      param.writeCharCode(char);
    }
  }
}

class _Csi {
  _Csi({
    required this.params,
    required this.finalByte,
    // required this.intermediates,
  });

  int? prefix;

  List<int> params;

  /// Sub-parameters separated by ':' (colon) in CSI sequences.
  /// Maps param index → list of sub-parameter values.
  /// E.g., `CSI 4:3m` → params=[4], subParams={0: [3]}
  final Map<int, List<int>> subParams = {};

  int finalByte;

  /// Intermediate bytes (0x20-0x2F range, e.g. `$` in DECRQM `CSI ? Ps $ p`).
  /// Most CSI sequences have no intermediates, but DECRQM uses `$`.
  final List<int> intermediates = [];

  @override
  String toString() {
    return params.join(';') + String.fromCharCode(finalByte);
  }
}

/// Function that handles a sequence of characters that starts with an escape.
/// Returns [true] if the sequence was processed, [false] if it was not.
typedef _EscHandler = bool Function();

typedef _SbcHandler = void Function();

typedef _CsiHandler = void Function();
