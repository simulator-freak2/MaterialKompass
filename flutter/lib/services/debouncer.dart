import 'dart:async';

/// Coalesces rapid UI events such as keystrokes into one update.
class Debouncer {
  Debouncer({this.delay = const Duration(milliseconds: 180)});

  final Duration delay;
  Timer? _timer;

  void run(void Function() action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
