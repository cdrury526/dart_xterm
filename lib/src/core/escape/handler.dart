import 'package:dart_xterm/src/core/mouse/mode.dart';

abstract class EscapeHandler {
  void writeChar(int char);

  /* SBC */

  void bell();

  void backspaceReturn();

  void tab();

  void lineFeed();

  void carriageReturn();

  void shiftOut();

  void shiftIn();

  void unknownSBC(int char);

  /* ANSI sequence */

  void saveCursor();

  void restoreCursor();

  void index();

  void nextLine();

  void setTapStop();

  void reverseIndex();

  void designateCharset(int charset, int name);

  void unkownEscape(int char);

  /* CSI */

  void repeatPreviousCharacter(int n);

  void setCursor(int x, int y);

  void setCursorX(int x);

  void setCursorY(int y);

  void sendPrimaryDeviceAttributes();

  void clearTabStopUnderCursor();

  void clearAllTabStops();

  void moveCursorX(int offset);

  void moveCursorY(int n);

  void sendSecondaryDeviceAttributes();

  void sendTertiaryDeviceAttributes();

  /// XTVERSION (CSI > 0 q) — report terminal name and version.
  /// Response: DCS > | name(version) ST
  void sendXtVersion();

  /// XTGETTCAP (DCS + q Pt ST) — request terminfo capability strings.
  /// [names] contains decoded termcap names such as `TN`, `Co`, or `RGB`.
  void requestTermcap(List<String> names);

  /// DECRQM (CSI ? Ps $ p / CSI Ps $ p) — request mode status.
  /// [mode] is the mode number, [isDec] distinguishes DEC private modes
  /// from ANSI modes. Response: CSI [?] Ps ; Pm $ y
  void requestMode(int mode, {required bool isDec});

  /// Kitty keyboard protocol — CSI > Ps u (push mode), CSI < u (pop mode),
  /// CSI ? u (query mode). We accept these silently (responding with mode 0
  /// for queries) so apps that probe for kitty keyboard support don't get
  /// confused by unknown-CSI errors.
  void kittyKeyboardMode({required int flags, required int action});

  void sendOperatingStatus();

  void sendCursorPosition();

  void setMargins(int i, [int? bottom]);

  void cursorNextLine(int amount);

  void cursorPrecedingLine(int amount);

  void eraseDisplayBelow();

  void eraseDisplayAbove();

  void eraseDisplay();

  void eraseScrollbackOnly();

  void eraseLineRight();

  void eraseLineLeft();

  void eraseLine();

  void insertLines(int amount);

  void deleteLines(int amount);

  void deleteChars(int amount);

  void scrollUp(int amount);

  void scrollDown(int amount);

  void eraseChars(int amount);

  void insertBlankChars(int amount);

  void unknownCSI(int finalByte);

  /* Modes */

  void setInsertMode(bool enabled);

  void setLineFeedMode(bool enabled);

  void setUnknownMode(int mode, bool enabled);

  /* DEC Private modes */

  void setCursorKeysMode(bool enabled);

  void setReverseDisplayMode(bool enabled);

  void setOriginMode(bool enabled);

  void setColumnMode(bool enabled);

  void setAutoWrapMode(bool enabled);

  void setMouseMode(MouseMode mode);

  void setCursorBlinkMode(bool enabled);

  void setCursorVisibleMode(bool enabled);

  void useAltBuffer();

  void useMainBuffer();

  void clearAltBuffer();

  void setAppKeypadMode(bool enabled);

  void setReportFocusMode(bool enabled);

  void setMouseReportMode(MouseReportMode mode);

  void setAltBufferMouseScrollMode(bool enabled);

  void setBracketedPasteMode(bool enabled);

  void setSynchronizedOutputMode(bool enabled);

  void setUnknownDecMode(int mode, bool enabled);

  void resize(int cols, int rows);

  void sendSize();

  /* Select Graphic Rendition (SGR) */

  void resetCursorStyle();

  void setCursorBold();

  void setCursorFaint();

  void setCursorItalic();

  void setCursorUnderline();

  void setCursorBlink();

  void setCursorInverse();

  void setCursorInvisible();

  void setCursorStrikethrough();

  /// SGR 53 — set overline decoration.
  void setCursorOverline();

  void unsetCursorBold();

  void unsetCursorFaint();

  void unsetCursorItalic();

  void unsetCursorUnderline();

  void unsetCursorBlink();

  void unsetCursorInverse();

  void unsetCursorInvisible();

  void unsetCursorStrikethrough();

  /// SGR 55 — unset overline decoration.
  void unsetCursorOverline();

  void setForegroundColor16(int color);

  void setForegroundColor256(int index);

  void setForegroundColorRgb(int r, int g, int b);

  void resetForeground();

  void setBackgroundColor16(int color);

  void setBackgroundColor256(int index);

  void setBackgroundColorRgb(int r, int g, int b);

  void resetBackground();

  /// SGR 58:2::R:G:B — set underline color (RGB).
  void setUnderlineColorRgb(int r, int g, int b);

  /// SGR 58:5:N — set underline color (256 palette).
  void setUnderlineColor256(int index);

  /// SGR 59 — reset underline color to default.
  void resetUnderlineColor();

  void unsupportedStyle(int param);

  /* OSC */

  void setTitle(String name);

  void setIconName(String name);

  void unknownOSC(String code, List<String> args);

  /// OSC 8 — hyperlink. [uri] is the link target (empty string means end).
  /// [params] is the key=value parameter string (e.g. "id=foo").
  void setHyperlink(String uri, {String params = ''});

  /// OSC 52 — clipboard access. [clipboard] is the selection target
  /// (e.g. 'c' for clipboard, 'p' for primary). [data] is base64-encoded
  /// content, or '?' to request the clipboard contents.
  void clipboardAccess(String clipboard, String data);
}
