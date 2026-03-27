# dart_xterm — Production-Grade Terminal Emulator Widget for Flutter

Forked from [TerminalStudio/xterm.dart](https://github.com/TerminalStudio/xterm.dart) (v4.0.0, 634 stars). Actively maintained with critical bug fixes and Flutter 3.38+ compatibility.

## qdexcode

- **Project ID**: `e0273d34-522c-454c-af6b-031f04a9e77d`
- **GitHub**: https://github.com/cdrury526/dart_xterm
- **Development Plan**: `6cfd366b-56f1-48bc-9232-dc7219de1a5c` (shared with dart_pty)
- **Upstream**: `ba00ccb8-ddbf-4926-a773-e307cbc49c42` (TerminalStudio/xterm.dart)

## Reference Implementations (indexed in qdexcode)

| Repo | Project ID | What to reference |
|---|---|---|
| xterm.js (Microsoft) | `5e4a74c8-07a9-414e-a44f-d65a8776c266` | Gold standard escape sequences, buffer, reflow, input |
| xterm.dart (upstream) | `ba00ccb8-ddbf-4926-a773-e307cbc49c42` | Our fork base |

## Architecture

```
lib/
  src/
    terminal.dart              — Terminal state machine (write, input, resize, callbacks)
    terminal_view.dart         — Flutter widget (TerminalView)
    core/
      escape/parser.dart       — VT100/xterm escape sequence parser
      buffer/buffer.dart       — Screen buffer (main + alt)
      buffer/line.dart         — BufferLine with cell storage
      reflow.dart              — Line reflow on resize
      cursor.dart              — Cursor state + style
      input/handler.dart       — Keyboard input → escape sequences
      mouse/                   — Mouse event handling
    ui/
      render.dart              — CustomPainter terminal renderer
      painter.dart             — Low-level text painting
      custom_text_edit.dart    — TextInput bridge (keyboard fix here)
      controller.dart          — Selection, scrolling
      gesture/                 — Tap, drag, scroll handlers
    utils/
      circular_buffer.dart     — IndexAwareCircularBuffer (buffer corruption fix here)
```

## Bugs Fixed (from upstream xterm.dart)

| Issue | File | Fix | Status |
|---|---|---|---|
| #207: Keyboard broken on Flutter 3.32+ | `lib/src/ui/custom_text_edit.dart` | Added `View.of(context).viewId` to TextInput.attach | DONE |
| #222: scrollUp/scrollDown buffer corruption | `lib/src/core/buffer/buffer.dart` | Replaced index assignment with splice-based remove+insert (matches xterm.js) | DONE |
| #197: Can't select text after scrolling | `lib/src/ui/render.dart` | Threaded `paintOffset` through _paintSelection/_paintHighlights/_paintSegment | DONE |
| #199: Reflow data loss exceeding maxlines | `lib/src/core/buffer/buffer.dart` | Width reflow runs before height adjustment, cursor anchor tracking | DONE |

## Known Rendering Issues (to fix)

| Issue | Description | Likely cause |
|---|---|---|
| Box-drawing chars as thick bars | `─` (U+2500) renders as full-width block instead of thin line | Painter may be using wrong glyph width or fallback rendering |
| OSC title leak (`t:` on screen) | `\x1b]0;title\x07` not fully consumed by parser | Parser may not be handling OSC 0 correctly |
| Unexpected underlines | Some text appears underlined that shouldn't be | SGR (Select Graphic Rendition) sequence misinterpretation |
| Keyboard listener control char leak | Backspace was inserting spaces | Fixed: filter control chars (0x00-0x1F, 0x7F) in CustomKeyboardListener._onKeyEvent |

## Key Classes

**Terminal** (`lib/src/terminal.dart`):
- `write(String data)` — feed PTY output to terminal (parses escape sequences)
- `onOutput` callback — forwards keystrokes to PTY
- `onResize` callback — forwards size changes to PTY
- `onTitleChange`, `onBell`, `onIconChange` — terminal events

**TerminalView** (`lib/src/terminal_view.dart`):
- `autoResize: true` — auto-calls terminal.resize on widget size change
- `theme` — TerminalTheme for colors
- `textStyle` — font family, size
- `controller` — selection, scrolling

## Logging & Debugging

### TerminalDebugConfig

```dart
final terminal = Terminal(
  debugConfig: TerminalDebugConfig(
    logParseErrors: true,
    logUnhandledSequences: true,
    logBufferOperations: true,
    onLog: (level, component, msg) {
      print('[$level] $component: $msg');
    },
  ),
);
```

- **Default**: all logging off, zero overhead
- **logParseErrors**: reports malformed escape sequences with raw bytes
- **logUnhandledSequences**: reports valid but unimplemented sequences — critical for identifying xterm.js parity gaps
- **logBufferOperations**: reports edge cases in scroll/reflow/resize

### Escape Sequence Callbacks

```dart
// On the EscapeParser:
onParseError: (String sequence, String reason) { ... }
onUnhandledSequence: (String sequence) { ... }
```

These fire even without TerminalDebugConfig — useful for automated compatibility testing.

### Buffer Debug Assertions

Debug-mode assertions (`assert()`) verify buffer invariants after:
- scrollUp / scrollDown — all BufferLine indices valid
- reflow — line count matches expected
- resize — viewWidth/viewHeight consistent

These crash in debug mode with a clear message. Silent in release mode.

### Debugging escape sequence issues

1. Enable `logUnhandledSequences: true`
2. Run the program that renders incorrectly (e.g., vim, htop)
3. The log shows which sequences dart_xterm doesn't handle
4. Use qdexcode to search xterm.js (project `5e4a74c8`) for the sequence handler
5. Port the implementation to the Dart parser

### Debugging buffer corruption

1. Enable `logBufferOperations: true`
2. Reproduce the issue (scroll, resize, etc.)
3. Debug assertions will fire with the exact operation and state
4. Compare buffer behavior against xterm.js using qdexcode

## Wiring to a PTY

```dart
final terminal = Terminal();
final pty = Pty.start(shell, size: PtySize(rows: 24, cols: 80));

// PTY output → Terminal
pty.output.listen(terminal.write);

// Terminal keystrokes → PTY
terminal.onOutput = (data) => pty.write(Uint8List.fromList(data.codeUnits));

// Terminal resize → PTY
terminal.onResize = (w, h, pw, ph) => pty.resize(PtySize(rows: h, cols: w));

// Widget
TerminalView(terminal, autoResize: true)
```

## Build & Test

```bash
# Analyze
flutter analyze

# Run example app
cd example && flutter run -d macos

# Run tests
flutter test
```

## Key Gotchas (verified during implementation)

- **Package renamed from xterm to dart_xterm** — all imports use `package:dart_xterm/`. Barrel export is `package:dart_xterm/dart_xterm.dart`.
- **PTY output must be UTF-8 decoded** — use `Utf8Decoder(allowMalformed: true).convert(data)` before `terminal.write()`. Never use `String.fromCharCodes()` — breaks multi-byte characters.
- **TERM=xterm-256color** — callers must set this in the PTY environment or zsh backspace/cursor breaks.
- **hardwareKeyboardOnly: true for desktop** — use this on desktop to avoid TextInput system intercepting keys. The CustomTextEdit path is for mobile soft keyboards.
- **fontFamily must be a single font name** — `TerminalStyle(fontFamily: 'Menlo')` not CSS-style comma-separated lists.
- **withOpacity deprecated** — use `withValues(alpha: x)` instead (Flutter 3.38+).
- **1 pre-existing golden test failure** — text_scale_factor test has pixel differences, unrelated to our changes.
- **No file over 600 lines** — terminal.dart is 906 lines in the upstream fork and should be split.

## Companion Package

**dart_pty** (`/Users/chrisdrury/projects/dart_pty`, qdexcode: `c1308426-62c4-4361-82b4-3e819dd5c96f`) — native FFI PTY package. dart_xterm provides the rendering, dart_pty provides the shell process. They're independent packages connected in the example app.
