import 'dart:math' show max;

import 'package:dart_xterm/src/base/observable.dart';
import 'package:dart_xterm/src/core/buffer/buffer.dart';
import 'package:dart_xterm/src/core/buffer/cell_offset.dart';
import 'package:dart_xterm/src/core/buffer/line.dart';
import 'package:dart_xterm/src/core/cursor.dart';
import 'package:dart_xterm/src/core/escape/emitter.dart';
import 'package:dart_xterm/src/core/escape/handler.dart';
import 'package:dart_xterm/src/core/escape/parser.dart';
import 'package:dart_xterm/src/core/input/handler.dart';
import 'package:dart_xterm/src/core/input/keys.dart';
import 'package:dart_xterm/src/core/mouse/button.dart';
import 'package:dart_xterm/src/core/mouse/button_state.dart';
import 'package:dart_xterm/src/core/mouse/handler.dart';
import 'package:dart_xterm/src/core/mouse/mode.dart';
import 'package:dart_xterm/src/core/platform.dart';
import 'package:dart_xterm/src/core/state.dart';
import 'package:dart_xterm/src/core/tabs.dart';
import 'package:dart_xterm/src/terminal_debug_config.dart';
import 'package:dart_xterm/src/utils/ascii.dart';
import 'package:dart_xterm/src/utils/circular_buffer.dart';

/// [Terminal] is an interface to interact with command line applications. It
/// translates escape sequences from the application into updates to the
/// [buffer] and events such as [onTitleChange] or [onBell], as well as
/// translating user input into escape sequences that the application can
/// understand.
class Terminal with Observable implements TerminalState, EscapeHandler {
  /// The number of lines that the scrollback buffer can hold. If the buffer
  /// exceeds this size, the lines at the top of the buffer will be removed.
  final int maxLines;

  /// Function that is called when the program requests the terminal to ring
  /// the bell. If not set, the terminal will do nothing.
  void Function()? onBell;

  /// Function that is called when the program requests the terminal to change
  /// the title of the window to [title].
  void Function(String title)? onTitleChange;

  /// Function that is called when the program requests the terminal to change
  /// the icon of the window. [icon] is the name of the icon.
  void Function(String icon)? onIconChange;

  /// Function that is called when the terminal emits data to the underlying
  /// program. This is typically caused by user inputs from [textInput],
  /// [keyInput], [mouseInput], or [paste].
  void Function(String data)? onOutput;

  /// Function that is called when the dimensions of the terminal change.
  void Function(int width, int height, int pixelWidth, int pixelHeight)?
      onResize;

  /// The [TerminalInputHandler] used by this terminal. [defaultInputHandler] is
  /// used when not specified. User of this class can provide their own
  /// implementation of [TerminalInputHandler] or extend [defaultInputHandler]
  /// with [CascadeInputHandler].
  TerminalInputHandler? inputHandler;

  TerminalMouseHandler? mouseHandler;

  /// The callback that is called when the terminal receives a unrecognized
  /// escape sequence.
  void Function(String code, List<String> args)? onPrivateOSC;

  /// Flag to toggle os specific behaviors.
  final TerminalTargetPlatform platform;

  /// Characters that break selection when double clicking. If not set, the
  /// [Buffer.defaultWordSeparators] will be used.
  final Set<int>? wordSeparators;

  /// Optional debug configuration for logging escape sequences, buffer
  /// operations, and other terminal internals. When not provided (or set to
  /// [TerminalDebugConfig.disabled]), adds zero overhead.
  @override
  final TerminalDebugConfig debugConfig;

  Terminal({
    this.maxLines = 1000,
    this.onBell,
    this.onTitleChange,
    this.onIconChange,
    this.onOutput,
    this.onResize,
    this.platform = TerminalTargetPlatform.unknown,
    this.inputHandler = defaultInputHandler,
    this.mouseHandler = defaultMouseHandler,
    this.onPrivateOSC,
    this.reflowEnabled = true,
    this.wordSeparators,
    this.debugConfig = const TerminalDebugConfig(),
    EscapeEmitter? emitter,
  }) : _emitter = emitter ?? const EscapeEmitter();

  late final _parser = EscapeParser(
    this,
    onParseError: debugConfig.onParseError,
    onUnhandledSequence: debugConfig.onUnhandledSequence,
  );

  /// The escape sequence emitter that generates responses to DA, DECRQM,
  /// XTVERSION, and other terminal capability queries. Configure this via
  /// the [emitter] constructor parameter to customize capability responses.
  final EscapeEmitter _emitter;

  late var _buffer = _mainBuffer;

  late final _mainBuffer = Buffer(
    this,
    maxLines: maxLines,
    isAltBuffer: false,
    wordSeparators: wordSeparators,
  );

  late final _altBuffer = Buffer(
    this,
    maxLines: maxLines,
    isAltBuffer: true,
    wordSeparators: wordSeparators,
  );

  final _tabStops = TabStops();

  /// The last character written to the buffer. Used to implement some escape
  /// sequences that repeat the last character.
  var _precedingCodepoint = 0;

  /* TerminalState */

  int _viewWidth = 80;

  int _viewHeight = 24;

  final _cursorStyle = CursorStyle();

  bool _insertMode = false;

  bool _lineFeedMode = false;

  bool _cursorKeysMode = false;

  bool _reverseDisplayMode = false;

  bool _originMode = false;

  bool _autoWrapMode = true;

  MouseMode _mouseMode = MouseMode.none;

  MouseReportMode _mouseReportMode = MouseReportMode.normal;

  bool _cursorBlinkMode = false;

  bool _cursorVisibleMode = true;

  bool _appKeypadMode = false;

  bool _reportFocusMode = false;

  bool _altBufferMouseScrollMode = false;

  bool _bracketedPasteMode = false;

  /* State getters */

  /// Number of cells in a terminal row.
  @override
  int get viewWidth => _viewWidth;

  /// Number of rows in this terminal.
  @override
  int get viewHeight => _viewHeight;

  @override
  CursorStyle get cursor => _cursorStyle;

  @override
  bool get insertMode => _insertMode;

  @override
  bool get lineFeedMode => _lineFeedMode;

  @override
  bool get cursorKeysMode => _cursorKeysMode;

  @override
  bool get reverseDisplayMode => _reverseDisplayMode;

  @override
  bool get originMode => _originMode;

  @override
  bool get autoWrapMode => _autoWrapMode;

  @override
  MouseMode get mouseMode => _mouseMode;

  @override
  MouseReportMode get mouseReportMode => _mouseReportMode;

  @override
  bool get cursorBlinkMode => _cursorBlinkMode;

  @override
  bool get cursorVisibleMode => _cursorVisibleMode;

  @override
  bool get appKeypadMode => _appKeypadMode;

  @override
  bool get reportFocusMode => _reportFocusMode;

  @override
  bool get altBufferMouseScrollMode => _altBufferMouseScrollMode;

  @override
  bool get bracketedPasteMode => _bracketedPasteMode;

  /// Current active buffer of the terminal. This is initially [mainBuffer] and
  /// can be switched back and forth from [altBuffer] to [mainBuffer] when
  /// the underlying program requests it.
  Buffer get buffer => _buffer;

  Buffer get mainBuffer => _mainBuffer;

  Buffer get altBuffer => _altBuffer;

  bool get isUsingAltBuffer => _buffer == _altBuffer;

  /// Lines of the active buffer.
  IndexAwareCircularBuffer<BufferLine> get lines => _buffer.lines;

  /// Whether the terminal performs reflow when the viewport size changes or
  /// simply truncates lines. true by default.
  @override
  bool reflowEnabled;

  /// Writes the data from the underlying program to the terminal. Calling this
  /// updates the states of the terminal and emits events such as [onBell] or
  /// [onTitleChange] when the escape sequences in [data] request it.
  void write(String data) {
    _parser.write(data);
    notifyListeners();
  }

  /// Sends a key event to the underlying program.
  ///
  /// See also:
  /// - [charInput]
  /// - [textInput]
  /// - [paste]
  bool keyInput(
    TerminalKey key, {
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
  }) {
    final output = inputHandler?.call(
      TerminalKeyboardEvent(
        key: key,
        shift: shift,
        alt: alt,
        ctrl: ctrl,
        state: this,
        altBuffer: isUsingAltBuffer,
        platform: platform,
      ),
    );

    if (output != null) {
      onOutput?.call(output);
      return true;
    }

    return false;
  }

  /// Similary to [keyInput], but takes a character as input instead of a
  /// [TerminalKey].
  ///
  /// See also:
  /// - [keyInput]
  /// - [textInput]
  /// - [paste]
  bool charInput(
    int charCode, {
    bool alt = false,
    bool ctrl = false,
  }) {
    if (ctrl) {
      // a(97) ~ z(122)
      if (charCode >= Ascii.a && charCode <= Ascii.z) {
        final output = charCode - Ascii.a + 1;
        onOutput?.call(String.fromCharCode(output));
        return true;
      }

      // [(91) ~ _(95)
      if (charCode >= Ascii.openBracket && charCode <= Ascii.underscore) {
        final output = charCode - Ascii.openBracket + 27;
        onOutput?.call(String.fromCharCode(output));
        return true;
      }
    }

    if (alt && platform != TerminalTargetPlatform.macos) {
      if (charCode >= Ascii.a && charCode <= Ascii.z) {
        final code = charCode - Ascii.a + 65;
        final input = [0x1b, code];
        onOutput?.call(String.fromCharCodes(input));
        return true;
      }
    }

    return false;
  }

  /// Sends regular text input to the underlying program.
  ///
  /// See also:
  /// - [keyInput]
  /// - [charInput]
  /// - [paste]
  void textInput(String text) {
    onOutput?.call(text);
  }

  /// Similar to [textInput], except that when the program tells the terminal
  /// that it supports [bracketedPasteMode], the text is wrapped in escape
  /// sequences to indicate that it is a paste operation. Prefer this method
  /// over [textInput] when pasting text.
  ///
  /// See also:
  /// - [textInput]
  void paste(String text) {
    if (_bracketedPasteMode) {
      onOutput?.call(_emitter.bracketedPaste(text));
    } else {
      textInput(text);
    }
  }

  // Handle a mouse event and return true if it was handled.
  bool mouseInput(
    TerminalMouseButton button,
    TerminalMouseButtonState buttonState,
    CellOffset position,
  ) {
    final output = mouseHandler?.call(TerminalMouseEvent(
      button: button,
      buttonState: buttonState,
      position: position,
      state: this,
      platform: platform,
    ));
    if (output != null) {
      onOutput?.call(output);
      return true;
    }
    return false;
  }

  /// Resize the terminal screen. [newWidth] and [newHeight] should be greater
  /// than 0. Text reflow is currently not implemented and will be avaliable in
  /// the future.
  @override
  void resize(
    int newWidth,
    int newHeight, [
    int? pixelWidth,
    int? pixelHeight,
  ]) {
    newWidth = max(newWidth, 1);
    newHeight = max(newHeight, 1);

    onResize?.call(newWidth, newHeight, pixelWidth ?? 0, pixelHeight ?? 0);

    //we need to resize both buffers so that they are ready when we switch between them
    _altBuffer.resize(_viewWidth, _viewHeight, newWidth, newHeight);
    _mainBuffer.resize(_viewWidth, _viewHeight, newWidth, newHeight);

    _viewWidth = newWidth;
    _viewHeight = newHeight;

    if (buffer == _altBuffer) {
      buffer.clearScrollback();
    }

    _altBuffer.resetVerticalMargins();
    _mainBuffer.resetVerticalMargins();
  }

  @override
  String toString() {
    return 'Terminal(#$hashCode, $_viewWidth x $_viewHeight, ${_buffer.height} lines)';
  }

  /* Handlers */

  @override
  void writeChar(int char) {
    _precedingCodepoint = char;
    _buffer.writeChar(char);
  }

  /* SBC */

  @override
  void bell() {
    onBell?.call();
  }

  @override
  void backspaceReturn() {
    _buffer.moveCursorX(-1);
  }

  @override
  void tab() {
    final nextStop = _tabStops.find(_buffer.cursorX + 1, _viewWidth);

    if (nextStop != null) {
      _buffer.setCursorX(nextStop);
    } else {
      _buffer.setCursorX(_viewWidth);
      _buffer.cursorGoForward(); // Enter pending-wrap state
    }
  }

  @override
  void lineFeed() {
    _buffer.lineFeed();
  }

  @override
  void carriageReturn() {
    _buffer.setCursorX(0);
  }

  @override
  void shiftOut() {
    _buffer.charset.use(1);
  }

  @override
  void shiftIn() {
    _buffer.charset.use(0);
  }

  @override
  void unknownSBC(int char) {
    // no-op
  }

  /* ANSI sequence */

  @override
  void saveCursor() {
    _buffer.saveCursor();
  }

  @override
  void restoreCursor() {
    _buffer.restoreCursor();
  }

  @override
  void index() {
    _buffer.index();
  }

  @override
  void nextLine() {
    _buffer.index();
    _buffer.setCursorX(0);
  }

  @override
  void setTapStop() {
    _tabStops.isSetAt(_buffer.cursorX);
  }

  @override
  void reverseIndex() {
    _buffer.reverseIndex();
  }

  @override
  void designateCharset(int charset, int name) {
    _buffer.charset.designate(charset, name);
  }

  @override
  void unkownEscape(int char) {
    if (debugConfig.logUnhandledSequences) {
      final seq = 'ESC ${String.fromCharCode(char)} (0x${char.toRadixString(16)})';
      debugConfig.onUnhandledSequence?.call(seq);
      debugConfig.onLog?.call('warn', 'parser', 'Unhandled escape: $seq');
    }
  }

  /* CSI */

  @override
  void repeatPreviousCharacter(int count) {
    if (_precedingCodepoint == 0) {
      return;
    }

    for (var i = 0; i < count; i++) {
      _buffer.writeChar(_precedingCodepoint);
    }
  }

  @override
  void setCursor(int x, int y) {
    _buffer.setCursor(x, y);
  }

  @override
  void setCursorX(int x) {
    _buffer.setCursorX(x);
  }

  @override
  void setCursorY(int y) {
    _buffer.setCursorY(y);
  }

  @override
  void moveCursorX(int offset) {
    _buffer.moveCursorX(offset);
  }

  @override
  void moveCursorY(int n) {
    _buffer.moveCursorY(n);
  }

  @override
  void clearTabStopUnderCursor() {
    _tabStops.clearAt(_buffer.cursorX);
  }

  @override
  void clearAllTabStops() {
    _tabStops.clearAll();
  }

  @override
  void sendPrimaryDeviceAttributes() {
    onOutput?.call(_emitter.primaryDeviceAttributes());
  }

  @override
  void sendSecondaryDeviceAttributes() {
    onOutput?.call(_emitter.secondaryDeviceAttributes());
  }

  @override
  void sendTertiaryDeviceAttributes() {
    onOutput?.call(_emitter.tertiaryDeviceAttributes());
  }

  @override
  void sendXtVersion() {
    onOutput?.call(_emitter.xtVersion());
  }

  @override
  void requestMode(int mode, {required bool isDec}) {
    // DECRPM values: 0=not recognized, 1=set, 2=reset,
    //               3=permanently set, 4=permanently reset
    int value;

    if (isDec) {
      // DEC private modes (CSI ? Ps $ p)
      value = _queryDecMode(mode);
    } else {
      // ANSI modes (CSI Ps $ p)
      value = _queryAnsiMode(mode);
    }

    onOutput?.call(_emitter.decRequestMode(mode, value, isDec: isDec));
  }

  /// Query the current state of a DEC private mode for DECRQM.
  ///
  /// Returns DECRPM status values:
  ///   0 = not recognized
  ///   1 = set (enabled)
  ///   2 = reset (disabled)
  ///   3 = permanently set
  ///   4 = permanently reset
  int _queryDecMode(int mode) {
    switch (mode) {
      case 1: // DECCKM — Application Cursor Keys
        return _cursorKeysMode ? 1 : 2;
      case 3: // DECCOLM — 132 Column Mode (not supported)
        return 0;
      case 5: // DECSCNM — Reverse Video
        return _reverseDisplayMode ? 1 : 2;
      case 6: // DECOM — Origin Mode
        return _originMode ? 1 : 2;
      case 7: // DECAWM — Auto Wrap Mode
        return _autoWrapMode ? 1 : 2;
      case 8: // DECARM — Auto Repeat (always on)
        return 3;
      case 9: // X10 mouse reporting
        return _mouseMode == MouseMode.clickOnly ? 1 : 2;
      case 12: // Cursor blink (att610)
        return _cursorBlinkMode ? 1 : 2;
      case 25: // DECTCEM — Cursor visible
        return _cursorVisibleMode ? 1 : 2;
      case 45: // Reverse wraparound (not supported)
        return 0;
      case 47: // Use alt screen buffer
        return isUsingAltBuffer ? 1 : 2;
      case 66: // DECNKM — Application Keypad Mode
        return _appKeypadMode ? 1 : 2;
      case 67: // DECBKM — Backarrow sends BS (permanently reset)
        return 4;
      case 1000: // VT200 mouse — Send Mouse X & Y on button press
        return _mouseMode == MouseMode.clickOnly ? 1 : 2;
      case 1002: // Button event (drag) mouse tracking
        return _mouseMode == MouseMode.upDownScrollDrag ? 1 : 2;
      case 1003: // Any event mouse tracking
        return _mouseMode == MouseMode.upDownScrollMove ? 1 : 2;
      case 1004: // Send focus events
        return _reportFocusMode ? 1 : 2;
      case 1005: // UTF-8 mouse encoding (permanently reset, legacy)
        return 4;
      case 1006: // SGR mouse encoding
        return _mouseReportMode == MouseReportMode.sgr ? 1 : 2;
      case 1015: // Urxvt mouse encoding (permanently reset)
        return 4;
      case 1047: // Use alt screen buffer
        return isUsingAltBuffer ? 1 : 2;
      case 1048: // Save/restore cursor (always set per xterm behavior)
        return 1;
      case 1049: // Alt buffer + save/restore cursor
        return isUsingAltBuffer ? 1 : 2;
      case 2004: // Bracketed paste mode
        return _bracketedPasteMode ? 1 : 2;
      default:
        return 0; // Not recognized
    }
  }

  /// Query the current state of an ANSI mode for DECRQM.
  int _queryAnsiMode(int mode) {
    switch (mode) {
      case 2: // KAM — Keyboard Action Mode (permanently reset)
        return 4;
      case 4: // IRM — Insert Mode
        return _insertMode ? 1 : 2;
      case 12: // SRM — Send/Receive (permanently set — local echo off)
        return 3;
      case 20: // LNM — Line Feed / New Line Mode
        return _lineFeedMode ? 1 : 2;
      default:
        return 0; // Not recognized
    }
  }

  @override
  void sendOperatingStatus() {
    onOutput?.call(_emitter.operatingStatus());
  }

  @override
  void sendCursorPosition() {
    onOutput?.call(_emitter.cursorPosition(_buffer.cursorX, _buffer.cursorY));
  }

  @override
  void setMargins(int top, [int? bottom]) {
    _buffer.setVerticalMargins(top, bottom ?? viewHeight - 1);
  }

  @override
  void cursorNextLine(int amount) {
    _buffer.moveCursorY(amount);
    _buffer.setCursorX(0);
  }

  @override
  void cursorPrecedingLine(int amount) {
    _buffer.moveCursorY(-amount);
    _buffer.setCursorX(0);
  }

  @override
  void eraseDisplayBelow() {
    _buffer.eraseDisplayFromCursor();
  }

  @override
  void eraseDisplayAbove() {
    _buffer.eraseDisplayToCursor();
  }

  @override
  void eraseDisplay() {
    _buffer.eraseDisplay();
  }

  @override
  void eraseScrollbackOnly() {
    _buffer.clearScrollback();
  }

  @override
  void eraseLineRight() {
    _buffer.eraseLineFromCursor();
  }

  @override
  void eraseLineLeft() {
    _buffer.eraseLineToCursor();
  }

  @override
  void eraseLine() {
    _buffer.eraseLine();
  }

  @override
  void insertLines(int amount) {
    _buffer.insertLines(amount);
  }

  @override
  void deleteLines(int amount) {
    _buffer.deleteLines(amount);
  }

  @override
  void deleteChars(int amount) {
    _buffer.deleteChars(amount);
  }

  @override
  void scrollUp(int amount) {
    _buffer.scrollUp(amount);
  }

  @override
  void scrollDown(int amount) {
    _buffer.scrollDown(amount);
  }

  @override
  void eraseChars(int amount) {
    _buffer.eraseChars(amount);
  }

  @override
  void insertBlankChars(int amount) {
    _buffer.insertBlankChars(amount);
  }

  @override
  void sendSize() {
    onOutput?.call(_emitter.size(viewHeight, viewWidth));
  }

  @override
  void unknownCSI(int finalByte) {
    if (debugConfig.logUnhandledSequences) {
      final seq =
          'CSI ... ${String.fromCharCode(finalByte)} (0x${finalByte.toRadixString(16)})';
      debugConfig.onUnhandledSequence?.call(seq);
      debugConfig.onLog?.call('warn', 'parser', 'Unhandled CSI: $seq');
    }
  }

  /* Modes */

  @override
  void setInsertMode(bool enabled) {
    _insertMode = enabled;
  }

  @override
  void setLineFeedMode(bool enabled) {
    _lineFeedMode = enabled;
  }

  @override
  void setUnknownMode(int mode, bool enabled) {
    if (debugConfig.logUnhandledSequences) {
      final action = enabled ? 'set' : 'reset';
      final seq = 'CSI $mode ${enabled ? "h" : "l"} (mode $action)';
      debugConfig.onUnhandledSequence?.call(seq);
      debugConfig.onLog?.call(
          'warn', 'parser', 'Unhandled mode: $seq');
    }
  }

  /* DEC Private modes */

  @override
  void setCursorKeysMode(bool enabled) {
    _cursorKeysMode = enabled;
  }

  @override
  void setReverseDisplayMode(bool enabled) {
    _reverseDisplayMode = enabled;
  }

  @override
  void setOriginMode(bool enabled) {
    _originMode = enabled;
  }

  @override
  void setColumnMode(bool enabled) {
    // no-op
  }

  @override
  void setAutoWrapMode(bool enabled) {
    _autoWrapMode = enabled;
  }

  @override
  void setMouseMode(MouseMode mode) {
    _mouseMode = mode;
  }

  @override
  void setCursorBlinkMode(bool enabled) {
    _cursorBlinkMode = enabled;
  }

  @override
  void setCursorVisibleMode(bool enabled) {
    _cursorVisibleMode = enabled;
  }

  @override
  void useAltBuffer() {
    _buffer = _altBuffer;
  }

  @override
  void useMainBuffer() {
    _buffer = _mainBuffer;
  }

  @override
  void clearAltBuffer() {
    _altBuffer.clear();
  }

  @override
  void setAppKeypadMode(bool enabled) {
    _appKeypadMode = enabled;
  }

  @override
  void setReportFocusMode(bool enabled) {
    _reportFocusMode = enabled;
  }

  @override
  void setMouseReportMode(MouseReportMode mode) {
    _mouseReportMode = mode;
  }

  @override
  void setAltBufferMouseScrollMode(bool enabled) {
    _altBufferMouseScrollMode = enabled;
  }

  @override
  void setBracketedPasteMode(bool enabled) {
    _bracketedPasteMode = enabled;
  }

  @override
  void setUnknownDecMode(int mode, bool enabled) {
    if (debugConfig.logUnhandledSequences) {
      final action = enabled ? 'set' : 'reset';
      final seq = 'CSI ? $mode ${enabled ? "h" : "l"} (DECSET/DECRST $action)';
      debugConfig.onUnhandledSequence?.call(seq);
      debugConfig.onLog?.call(
          'warn', 'parser', 'Unhandled DEC private mode: $seq');
    }
  }

  /* Select Graphic Rendition (SGR) */

  @override
  void resetCursorStyle() {
    _cursorStyle.reset();
  }

  @override
  void setCursorBold() {
    _cursorStyle.setBold();
  }

  @override
  void setCursorFaint() {
    _cursorStyle.setFaint();
  }

  @override
  void setCursorItalic() {
    _cursorStyle.setItalic();
  }

  @override
  void setCursorUnderline() {
    // Suppress underline when an OSC 8 hyperlink is active.
    // Apps like Claude Code pair SGR 4m with OSC 8 hyperlinks, but
    // terminals that support OSC 8 don't show the SGR underline.
    if (!_hyperlinkActive) {
      _cursorStyle.setUnderline();
    }
  }

  @override
  void setCursorBlink() {
    _cursorStyle.setBlink();
  }

  @override
  void setCursorInverse() {
    _cursorStyle.setInverse();
  }

  @override
  void setCursorInvisible() {
    _cursorStyle.setInvisible();
  }

  @override
  void setCursorStrikethrough() {
    _cursorStyle.setStrikethrough();
  }

  @override
  void unsetCursorBold() {
    _cursorStyle.unsetBold();
  }

  @override
  void unsetCursorFaint() {
    _cursorStyle.unsetFaint();
  }

  @override
  void unsetCursorItalic() {
    _cursorStyle.unsetItalic();
  }

  @override
  void unsetCursorUnderline() {
    _cursorStyle.unsetUnderline();
  }

  @override
  void unsetCursorBlink() {
    _cursorStyle.unsetBlink();
  }

  @override
  void unsetCursorInverse() {
    _cursorStyle.unsetInverse();
  }

  @override
  void unsetCursorInvisible() {
    _cursorStyle.unsetInvisible();
  }

  @override
  void unsetCursorStrikethrough() {
    _cursorStyle.unsetStrikethrough();
  }

  @override
  void setForegroundColor16(int color) {
    _cursorStyle.setForegroundColor16(color);
  }

  @override
  void setForegroundColor256(int index) {
    _cursorStyle.setForegroundColor256(index);
  }

  @override
  void setForegroundColorRgb(int r, int g, int b) {
    _cursorStyle.setForegroundColorRgb(r, g, b);
  }

  @override
  void resetForeground() {
    _cursorStyle.resetForegroundColor();
  }

  @override
  void setBackgroundColor16(int color) {
    _cursorStyle.setBackgroundColor16(color);
  }

  @override
  void setBackgroundColor256(int index) {
    _cursorStyle.setBackgroundColor256(index);
  }

  @override
  void setBackgroundColorRgb(int r, int g, int b) {
    _cursorStyle.setBackgroundColorRgb(r, g, b);
  }

  @override
  void resetBackground() {
    _cursorStyle.resetBackgroundColor();
  }

  @override
  void unsupportedStyle(int param) {
    if (debugConfig.logUnhandledSequences) {
      final seq = 'SGR $param';
      debugConfig.onUnhandledSequence?.call(seq);
      debugConfig.onLog?.call('warn', 'parser', 'Unsupported SGR style: $seq');
    }
  }

  /* OSC */

  @override
  void setTitle(String name) {
    onTitleChange?.call(name);
  }

  @override
  void setIconName(String name) {
    onIconChange?.call(name);
  }

  @override
  void unknownOSC(String ps, List<String> pt) {
    onPrivateOSC?.call(ps, pt);
    if (debugConfig.logUnhandledSequences && onPrivateOSC == null) {
      final seq = 'OSC $ps ; ${pt.join(";")}';
      debugConfig.onUnhandledSequence?.call(seq);
      debugConfig.onLog?.call('warn', 'parser', 'Unhandled OSC: $seq');
    }
  }

  /// Whether a hyperlink (OSC 8) is currently active.
  bool _hyperlinkActive = false;

  @override
  void setHyperlink(bool active) {
    _hyperlinkActive = active;
    // When a hyperlink starts, suppress any SGR underline that was set
    // alongside it. Apps like Claude Code send SGR 4m with OSC 8, but
    // terminals that support OSC 8 (iTerm2) don't show the underline.
    if (active) {
      _cursorStyle.unsetUnderline();
    }
  }
}
