import 'package:dart_xterm/src/core/cursor.dart';
import 'package:dart_xterm/src/core/mouse/mode.dart';
import 'package:dart_xterm/src/terminal_debug_config.dart';

abstract class TerminalState {
  /// Debug configuration for logging. Defaults to disabled.
  TerminalDebugConfig get debugConfig;

  int get viewWidth;

  int get viewHeight;

  CursorStyle get cursor;

  bool get reflowEnabled;

  /* Modes */

  bool get insertMode;

  bool get lineFeedMode;

  /* DEC Private modes */

  bool get cursorKeysMode;

  bool get reverseDisplayMode;

  bool get originMode;

  bool get autoWrapMode;

  MouseMode get mouseMode;

  MouseReportMode get mouseReportMode;

  bool get cursorBlinkMode;

  bool get cursorVisibleMode;

  bool get appKeypadMode;

  bool get reportFocusMode;

  bool get altBufferMouseScrollMode;

  bool get bracketedPasteMode;

  bool get synchronizedOutputMode;
}
