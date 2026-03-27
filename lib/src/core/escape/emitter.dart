/// Generates escape sequence responses sent back to the PTY.
///
/// These responses are how the terminal advertises its capabilities to
/// programs running inside it. CLI tools like vim, htop, Claude Code,
/// Codex CLI, and Gemini CLI query the terminal via DA1/DA2/DA3 requests
/// and use the responses to decide which features to enable.
///
/// ## Configurable fields
///
/// - [termName] / [termVersion]: Reported in XTVERSION (`DCS > | text ST`).
///   CLI apps use this for terminal identification alongside the TERM_PROGRAM
///   env var.
///
/// - [da1Response]: Primary Device Attributes. Default `\e[?1;2c` identifies
///   as VT100 with Advanced Video Option — the same response xterm.js sends.
///   Apps use this to determine baseline capability level.
///
/// - [da2ModelCode] / [da2VersionCode]: Secondary Device Attributes. Encoded
///   as `\e[> Pp ; Pv ; 0 c`. Pp=0 means VT100, Pp=1 means VT220. The
///   version code is an integer (xterm sends 276, we send 100).
///
/// - [da3UnitId]: Tertiary Device Attributes. Eight hex characters identifying
///   the terminal unit. Sent as `DCS ! | XXXXXXXX ST`.
class EscapeEmitter {
  const EscapeEmitter({
    this.termName = 'magnet-terminal',
    this.termVersion = '0.1.0',
    this.da1Response = '\x1b[?1;2c',
    this.da2ModelCode = 0,
    this.da2VersionCode = 100,
    this.da3UnitId = '4D41474E',
  });

  /// Terminal name for XTVERSION response. Paired with TERM_PROGRAM env var.
  /// CLI apps use both for terminal identification.
  final String termName;

  /// Terminal version for XTVERSION response. Paired with
  /// TERM_PROGRAM_VERSION env var.
  final String termVersion;

  /// Raw DA1 response string including the escape prefix.
  ///
  /// Default `\e[?1;2c` = VT100 with Advanced Video Option, matching xterm.js.
  /// iTerm2 sends `\e[?62;4c` (VT220 with Sixel). For maximum CLI
  /// compatibility, the xterm-style response is the safest choice.
  final String da1Response;

  /// DA2 model code (Pp). 0 = VT100, 1 = VT220.
  ///
  /// xterm.js sends `\e[>0;276;0c` (VT100, version 276).
  final int da2ModelCode;

  /// DA2 firmware version code (Pv). xterm.js sends 276.
  ///
  /// We default to 100 to avoid version-sniffing issues while still
  /// identifying as a modern terminal.
  final int da2VersionCode;

  /// DA3 unit ID — eight hex characters. Sent as `DCS ! | XXXXXXXX ST`.
  ///
  /// Default `4D41474E` is ASCII for "MAGN" (magnet-terminal).
  final String da3UnitId;

  /// DA1 (CSI c) — Primary Device Attributes response.
  ///
  /// Tells the requesting program what class of terminal this is.
  /// The default `\e[?1;2c` means "VT100 with Advanced Video Option",
  /// which is the same response xterm.js sends. This is the most
  /// broadly compatible response for modern CLI apps.
  String primaryDeviceAttributes() {
    return da1Response;
  }

  /// DA2 (CSI > c) — Secondary Device Attributes response.
  ///
  /// Reports the terminal type and firmware version. The format is
  /// `\e[> Pp ; Pv ; Pc c` where:
  /// - Pp = terminal type (0=VT100, 1=VT220)
  /// - Pv = firmware version number
  /// - Pc = ROM cartridge registration (always 0)
  String secondaryDeviceAttributes() {
    return '\x1b[>$da2ModelCode;$da2VersionCode;0c';
  }

  /// DA3 (CSI = c) — Tertiary Device Attributes response.
  ///
  /// Reports the terminal unit ID as a DCS sequence: `DCS ! | XXXXXXXX ST`.
  /// The unit ID is eight hex characters.
  String tertiaryDeviceAttributes() {
    return '\x1bP!|$da3UnitId\x1b\\';
  }

  /// XTVERSION (CSI > 0 q) — Report terminal name and version.
  ///
  /// Response format: `DCS > | name(version) ST`.
  /// This is how CLI apps identify the terminal program when TERM_PROGRAM
  /// is not available or they want a more reliable signal. xterm.js responds
  /// with `xterm.js(VERSION)`, wezterm with `wezterm VERSION`.
  String xtVersion() {
    return '\x1bP>|$termName($termVersion)\x1b\\';
  }

  /// DECRQM response (DECRPM) — report mode status.
  ///
  /// Response format for DEC private modes: `CSI ? Ps ; Pm $ y`
  /// Response format for ANSI modes: `CSI Ps ; Pm $ y`
  ///
  /// Pm values (per DECRPM spec):
  /// - 0 = not recognized
  /// - 1 = set
  /// - 2 = reset
  /// - 3 = permanently set
  /// - 4 = permanently reset
  String decRequestMode(int mode, int value, {required bool isDec}) {
    if (isDec) {
      return '\x1b[?$mode;$value\$y';
    }
    return '\x1b[$mode;$value\$y';
  }

  String operatingStatus() {
    return '\x1b[0n';
  }

  String cursorPosition(int x, int y) {
    return '\x1b[$y;${x}R';
  }

  String bracketedPaste(String text) {
    return '\x1b[200~$text\x1b[201~';
  }

  String size(int rows, int cols) {
    return '\x1b[8;$rows;${cols}t';
  }
}
