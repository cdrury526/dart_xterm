import 'package:flutter/widgets.dart';

class CustomKeyboardListener extends StatelessWidget {
  final Widget child;

  final FocusNode focusNode;

  final bool autofocus;

  final void Function(String) onInsert;

  final void Function(String?) onComposing;

  final KeyEventResult Function(FocusNode, KeyEvent) onKeyEvent;

  const CustomKeyboardListener({
    super.key,
    required this.child,
    required this.focusNode,
    this.autofocus = false,
    required this.onInsert,
    required this.onComposing,
    required this.onKeyEvent,
  });

  KeyEventResult _onKeyEvent(FocusNode focusNode, KeyEvent keyEvent) {
    // First try to handle the key event directly.
    final handled = onKeyEvent(focusNode, keyEvent);
    if (handled == KeyEventResult.ignored) {
      // If it was not handled, but the key corresponds to a printable character,
      // insert the character. Filter out control characters (0x00-0x1F, 0x7F)
      // which should be handled as key events, not text insertions.
      final char = keyEvent.character;
      if (char != null && char.isNotEmpty) {
        final code = char.codeUnitAt(0);
        if (code >= 0x20 && code != 0x7f) {
          onInsert(char);
          return KeyEventResult.handled;
        }
      }
    }
    return handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      autofocus: autofocus,
      onKeyEvent: _onKeyEvent,
      child: child,
    );
  }
}
