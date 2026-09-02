import 'package:flutter/material.dart' hide DropdownButtonFormField;
import 'package:flutter/material.dart' as material show DropdownButtonFormField;
import 'package:flutter/services.dart';

typedef DropdownButtonFormField<T> = KeyboardDropdownButtonFormField<T>;

typedef DropdownItemSearchText<T> = String Function(DropdownMenuItem<T> item);

/// A [DropdownButtonFormField] with focus-scoped keyboard type-ahead.
///
/// When the field is focused and closed, typing selects the first matching
/// entry immediately. While its menu is open, typing only moves the highlight;
/// Enter or a pointer click confirms the selection. Repeated characters cycle
/// through entries with the same initial character, and characters entered
/// within [searchResetDelay] form a prefix.
class KeyboardDropdownButtonFormField<T> extends StatefulWidget {
  const KeyboardDropdownButtonFormField({
    super.key,
    required this.items,
    required this.onChanged,
    this.selectedItemBuilder,
    this.initialValue,
    this.hint,
    this.disabledHint,
    this.onTap,
    this.elevation = 8,
    this.style,
    this.icon,
    this.iconDisabledColor,
    this.iconEnabledColor,
    this.iconSize = 24.0,
    this.isDense = true,
    this.isExpanded = false,
    this.itemHeight,
    this.focusColor,
    this.focusNode,
    this.autofocus = false,
    this.dropdownColor,
    this.decoration,
    this.onSaved,
    this.validator,
    this.errorBuilder,
    this.forceErrorText,
    this.autovalidateMode,
    this.menuMaxHeight,
    this.enableFeedback,
    this.alignment = AlignmentDirectional.centerStart,
    this.borderRadius,
    this.padding,
    this.barrierDismissible = true,
    this.mouseCursor,
    this.dropdownMenuItemMouseCursor,
    this.itemSearchText,
    this.searchResetDelay = const Duration(milliseconds: 700),
  });

  final List<DropdownMenuItem<T>>? items;
  final DropdownButtonBuilder? selectedItemBuilder;
  final T? initialValue;
  final Widget? hint;
  final Widget? disabledHint;
  final ValueChanged<T?>? onChanged;
  final VoidCallback? onTap;
  final int elevation;
  final TextStyle? style;
  final Widget? icon;
  final Color? iconDisabledColor;
  final Color? iconEnabledColor;
  final double iconSize;
  final bool isDense;
  final bool isExpanded;
  final double? itemHeight;
  final Color? focusColor;
  final FocusNode? focusNode;
  final bool autofocus;
  final Color? dropdownColor;
  final InputDecoration? decoration;
  final FormFieldSetter<T>? onSaved;
  final FormFieldValidator<T>? validator;
  final FormFieldErrorBuilder? errorBuilder;
  final String? forceErrorText;
  final AutovalidateMode? autovalidateMode;
  final double? menuMaxHeight;
  final bool? enableFeedback;
  final AlignmentGeometry alignment;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final bool barrierDismissible;
  final MouseCursor? mouseCursor;
  final MouseCursor? dropdownMenuItemMouseCursor;
  final DropdownItemSearchText<T>? itemSearchText;
  final Duration searchResetDelay;

  @override
  State<KeyboardDropdownButtonFormField<T>> createState() =>
      _KeyboardDropdownButtonFormFieldState<T>();
}

class _KeyboardDropdownButtonFormFieldState<T>
    extends State<KeyboardDropdownButtonFormField<T>> {
  static const int _maxPrefixLength = 64;

  final GlobalKey<FormFieldState<T>> _fieldKey = GlobalKey<FormFieldState<T>>();
  final Stopwatch _searchClock = Stopwatch();

  List<FocusNode> _menuFocusNodes = const [];
  List<String> _normalizedLabels = const [];
  String _prefix = '';
  Duration _lastCharacterAt = Duration.zero;

  List<DropdownMenuItem<T>> get _items =>
      widget.items ?? <DropdownMenuItem<T>>[];

  @override
  void initState() {
    super.initState();
    _searchClock.start();
    _refreshItemCache();
  }

  @override
  void didUpdateWidget(covariant KeyboardDropdownButtonFormField<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _refreshItemCache();
  }

  @override
  void dispose() {
    for (final node in _menuFocusNodes) {
      node.dispose();
    }
    _searchClock.stop();
    super.dispose();
  }

  void _refreshItemCache() {
    final itemCount = _items.length;
    if (_menuFocusNodes.length != itemCount) {
      for (final node in _menuFocusNodes) {
        node.dispose();
      }
      _menuFocusNodes = List<FocusNode>.generate(
        itemCount,
        (index) => FocusNode(
          debugLabel: 'KeyboardDropdown menu item $index',
          skipTraversal: true,
        ),
      );
    }
    _normalizedLabels = List<String>.generate(itemCount, (index) {
      final item = _items[index];
      final label =
          widget.itemSearchText?.call(item) ?? _visibleText(item.child);
      return _normalize(label);
    }, growable: false);
  }

  KeyEventResult _handleClosedKey(FocusNode node, KeyEvent event) {
    if (!_isEnabled || !_isSupportedCharacterEvent(event)) {
      return KeyEventResult.ignored;
    }
    final match = _matchFor(event.character!, _selectedIndex);
    if (match == null) return KeyEventResult.ignored;

    final item = _items[match];
    item.onTap?.call();
    _fieldKey.currentState?.didChange(item.value);
    return KeyEventResult.handled;
  }

  KeyEventResult _handleOpenKey(int currentIndex, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _focusAdjacent(currentIndex, 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _focusAdjacent(currentIndex, -1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.home) {
      _focusFirstEnabled();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.end) {
      _focusLastEnabled();
      return KeyEventResult.handled;
    }
    if (!_isSupportedCharacterEvent(event)) {
      return KeyEventResult.ignored;
    }

    final match = _matchFor(event.character!, currentIndex);
    if (match == null) return KeyEventResult.ignored;
    _menuFocusNodes[match].requestFocus();
    return KeyEventResult.handled;
  }

  bool get _isEnabled =>
      widget.onChanged != null && widget.items != null && _items.isNotEmpty;

  int get _selectedIndex {
    final selectedValue = _fieldKey.currentState?.value ?? widget.initialValue;
    return _items.indexWhere((item) => item.value == selectedValue);
  }

  bool _isSupportedCharacterEvent(KeyEvent event) {
    if (event is! KeyDownEvent || event is KeyRepeatEvent) return false;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return false;
    }
    final character = event.character;
    if (character == null || character.runes.length != 1) return false;
    return RegExp(r'^[a-z0-9]$').hasMatch(_normalize(character));
  }

  int? _matchFor(String character, int currentIndex) {
    final normalizedCharacter = _normalize(character);
    if (normalizedCharacter.isEmpty) return null;

    final now = _searchClock.elapsed;
    final withinWindow = now - _lastCharacterAt <= widget.searchResetDelay;
    final repeatedInitial =
        withinWindow && _prefix.length == 1 && _prefix == normalizedCharacter;
    var candidate = withinWindow && !repeatedInitial
        ? '$_prefix$normalizedCharacter'
        : normalizedCharacter;
    if (candidate.length > _maxPrefixLength) {
      candidate = normalizedCharacter;
    }

    var matches = _matchingIndices(candidate);
    if (matches.isEmpty && candidate != normalizedCharacter) {
      candidate = normalizedCharacter;
      matches = _matchingIndices(candidate);
    }
    _prefix = candidate;
    _lastCharacterAt = now;
    if (matches.isEmpty) return null;

    if (repeatedInitial) {
      return matches.firstWhere(
        (index) => index > currentIndex,
        orElse: () => matches.first,
      );
    }
    return matches.first;
  }

  List<int> _matchingIndices(String prefix) {
    final matches = <int>[];
    for (var index = 0; index < _items.length; index++) {
      if (_items[index].enabled &&
          _normalizedLabels[index].startsWith(prefix)) {
        matches.add(index);
      }
    }
    return matches;
  }

  void _focusAdjacent(int currentIndex, int direction) {
    var index = currentIndex + direction;
    while (index >= 0 && index < _items.length) {
      if (_items[index].enabled) {
        _menuFocusNodes[index].requestFocus();
        return;
      }
      index += direction;
    }
  }

  void _focusFirstEnabled() {
    final index = _items.indexWhere((item) => item.enabled);
    if (index >= 0) _menuFocusNodes[index].requestFocus();
  }

  void _focusLastEnabled() {
    for (var index = _items.length - 1; index >= 0; index--) {
      if (_items[index].enabled) {
        _menuFocusNodes[index].requestFocus();
        return;
      }
    }
  }

  void _handleTap() {
    _prefix = '';
    _lastCharacterAt = Duration.zero;
    widget.onTap?.call();

    final selected = _selectedIndex;
    final initialIndex = selected >= 0 && _items[selected].enabled
        ? selected
        : _items.indexWhere((item) => item.enabled);
    if (initialIndex < 0) return;
    _focusMenuItemWhenAttached(initialIndex, attemptsRemaining: 4);
  }

  void _focusMenuItemWhenAttached(int index, {required int attemptsRemaining}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || index >= _menuFocusNodes.length) return;
      final node = _menuFocusNodes[index];
      if (node.context != null) {
        node.requestFocus();
      } else if (attemptsRemaining > 0) {
        _focusMenuItemWhenAttached(
          index,
          attemptsRemaining: attemptsRemaining - 1,
        );
      }
    });
  }

  List<DropdownMenuItem<T>> _menuItems() {
    return List<DropdownMenuItem<T>>.generate(_items.length, (index) {
      final item = _items[index];
      return DropdownMenuItem<T>(
        key: item.key,
        value: item.value,
        enabled: item.enabled,
        alignment: item.alignment,
        onTap: item.onTap,
        child: _KeyboardDropdownMenuItem(
          focusNode: _menuFocusNodes[index],
          enabled: item.enabled,
          onKeyEvent: (event) => _handleOpenKey(index, event),
          child: item.child,
        ),
      );
    }, growable: false);
  }

  List<Widget> _selectedItems(BuildContext context) {
    if (widget.selectedItemBuilder != null) {
      return widget.selectedItemBuilder!(context);
    }
    return _items.map((item) => item.child).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _handleClosedKey,
      child: material.DropdownButtonFormField<T>(
        key: _fieldKey,
        items: widget.items == null ? null : _menuItems(),
        selectedItemBuilder: _selectedItems,
        initialValue: widget.initialValue,
        hint: widget.hint,
        disabledHint: widget.disabledHint,
        onChanged: widget.onChanged,
        onTap: _isEnabled ? _handleTap : widget.onTap,
        elevation: widget.elevation,
        style: widget.style,
        icon: widget.icon,
        iconDisabledColor: widget.iconDisabledColor,
        iconEnabledColor: widget.iconEnabledColor,
        iconSize: widget.iconSize,
        isDense: widget.isDense,
        isExpanded: widget.isExpanded,
        itemHeight: widget.itemHeight,
        focusColor: widget.focusColor,
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        dropdownColor: widget.dropdownColor,
        decoration: widget.decoration,
        onSaved: widget.onSaved,
        validator: widget.validator,
        errorBuilder: widget.errorBuilder,
        forceErrorText: widget.forceErrorText,
        autovalidateMode: widget.autovalidateMode,
        menuMaxHeight: widget.menuMaxHeight,
        enableFeedback: widget.enableFeedback,
        alignment: widget.alignment,
        borderRadius: widget.borderRadius,
        padding: widget.padding,
        barrierDismissible: widget.barrierDismissible,
        mouseCursor: widget.mouseCursor,
        dropdownMenuItemMouseCursor: widget.dropdownMenuItemMouseCursor,
      ),
    );
  }
}

class _KeyboardDropdownMenuItem extends StatefulWidget {
  const _KeyboardDropdownMenuItem({
    required this.focusNode,
    required this.enabled,
    required this.onKeyEvent,
    required this.child,
  });

  final FocusNode focusNode;
  final bool enabled;
  final KeyEventResult Function(KeyEvent event) onKeyEvent;
  final Widget child;

  @override
  State<_KeyboardDropdownMenuItem> createState() =>
      _KeyboardDropdownMenuItemState();
}

class _KeyboardDropdownMenuItemState extends State<_KeyboardDropdownMenuItem> {
  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(covariant _KeyboardDropdownMenuItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      oldWidget.focusNode.removeListener(_handleFocusChange);
      widget.focusNode.addListener(_handleFocusChange);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_handleFocusChange);
    super.dispose();
  }

  void _handleFocusChange() {
    if (!mounted) return;
    setState(() {});
    if (widget.focusNode.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.focusNode.hasFocus) return;
        Scrollable.ensureVisible(
          context,
          alignment: 0.5,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeInOut,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      canRequestFocus: widget.enabled,
      skipTraversal: true,
      onKeyEvent: (_, event) => widget.onKeyEvent(event),
      child: Ink(
        color: widget.focusNode.hasFocus ? Theme.of(context).focusColor : null,
        child: widget.child,
      ),
    );
  }
}

String _visibleText(Widget widget) {
  if (widget is Text) {
    return widget.data ?? widget.textSpan?.toPlainText() ?? '';
  }
  if (widget is RichText) return widget.text.toPlainText();
  if (widget is ListTile) {
    return [widget.title, widget.subtitle]
        .whereType<Widget>()
        .map(_visibleText)
        .where((text) => text.isNotEmpty)
        .join(' ');
  }
  if (widget is Flex) {
    return widget.children
        .map(_visibleText)
        .where((text) => text.isNotEmpty)
        .join(' ');
  }
  if (widget is Wrap) {
    return widget.children
        .map(_visibleText)
        .where((text) => text.isNotEmpty)
        .join(' ');
  }
  if (widget is Stack) {
    return widget.children
        .map(_visibleText)
        .where((text) => text.isNotEmpty)
        .join(' ');
  }
  if (widget is ProxyWidget) return _visibleText(widget.child);
  if (widget is SingleChildRenderObjectWidget && widget.child != null) {
    return _visibleText(widget.child!);
  }
  return '';
}

String _normalize(String value) {
  var normalized = value.trim().toLowerCase();
  const replacements = <String, String>{
    'ä': 'a',
    'á': 'a',
    'à': 'a',
    'â': 'a',
    'ã': 'a',
    'å': 'a',
    'æ': 'a',
    'ç': 'c',
    'é': 'e',
    'è': 'e',
    'ê': 'e',
    'ë': 'e',
    'í': 'i',
    'ì': 'i',
    'î': 'i',
    'ï': 'i',
    'ñ': 'n',
    'ö': 'o',
    'ó': 'o',
    'ò': 'o',
    'ô': 'o',
    'õ': 'o',
    'ø': 'o',
    'ü': 'u',
    'ú': 'u',
    'ù': 'u',
    'û': 'u',
    'ý': 'y',
    'ÿ': 'y',
  };
  for (final replacement in replacements.entries) {
    normalized = normalized.replaceAll(replacement.key, replacement.value);
  }
  return normalized;
}
