/// Configuration for debug logging in the terminal emulator.
///
/// When all options are disabled (the default), this adds zero overhead
/// to production usage. Enable specific options to diagnose escape sequence
/// handling, buffer operations, or other terminal internals.
///
/// Example:
/// ```dart
/// final terminal = Terminal(
///   debugConfig: TerminalDebugConfig(
///     logParseErrors: true,
///     logUnhandledSequences: true,
///     logBufferOperations: true,
///     onLog: (level, component, msg) => print('[$level] $component: $msg'),
///   ),
/// );
/// ```
class TerminalDebugConfig {
  /// Whether to log malformed escape sequences via [onLog] and fire
  /// [onParseError].
  final bool logParseErrors;

  /// Whether to log valid but unimplemented escape sequences via [onLog]
  /// and fire [onUnhandledSequence]. This is critical for identifying
  /// missing xterm compatibility.
  final bool logUnhandledSequences;

  /// Whether to log buffer operations (scroll, reflow, resize) via [onLog]
  /// and fire [onBufferWarning] when edge cases are hit.
  final bool logBufferOperations;

  /// General-purpose log callback. Called for all enabled log categories.
  ///
  /// [level] is one of: `debug`, `warn`, `error`.
  /// [component] identifies the source: `parser`, `buffer`, `terminal`.
  /// [message] is a human-readable description of the event.
  final void Function(String level, String component, String message)? onLog;

  /// Called when a malformed escape sequence is encountered.
  ///
  /// [sequence] contains the raw bytes that could not be parsed.
  /// [reason] explains why parsing failed.
  final void Function(String sequence, String reason)? onParseError;

  /// Called when a valid but unimplemented escape sequence is received.
  ///
  /// [sequence] is a human-readable representation of the sequence
  /// (e.g., `CSI 1049 h` for alt buffer switch).
  final void Function(String sequence)? onUnhandledSequence;

  /// Called when buffer operations hit edge cases.
  ///
  /// [operation] is the name of the operation (e.g., `scrollUp`, `reflow`).
  /// [details] describes what was unexpected.
  final void Function(String operation, String details)? onBufferWarning;

  /// Called when the terminal emits a response back to the program.
  ///
  /// [kind] identifies the response category (for example `da1`,
  /// `xtversion`, or `decrqm`). [data] contains the exact bytes that will be
  /// sent through [Terminal.onOutput].
  final void Function(String kind, String data)? onTerminalResponse;

  const TerminalDebugConfig({
    this.logParseErrors = false,
    this.logUnhandledSequences = false,
    this.logBufferOperations = false,
    this.onLog,
    this.onParseError,
    this.onUnhandledSequence,
    this.onBufferWarning,
    this.onTerminalResponse,
  });

  /// Default config with all logging disabled. Zero overhead in production.
  static const disabled = TerminalDebugConfig();

  /// Whether any logging is enabled. Used for fast-path checks to avoid
  /// string formatting when logging is off.
  bool get isEnabled =>
      logParseErrors || logUnhandledSequences || logBufferOperations;
}
