import 'package:flutter_test/flutter_test.dart';
import 'package:materialkompass/services/user_activity.dart';

void main() {
  late DateTime now;
  final activity = UserActivity.instance;

  setUp(() {
    now = DateTime(2026, 11, 15, 8);
    activity.clock = () => now;
    activity.startSession();
  });

  tearDown(() => activity.clock = DateTime.now);

  test('input keeps the login alive, 60 idle minutes end it', () {
    now = now.add(const Duration(minutes: 59));
    expect(activity.expired, isFalse);
    activity.recordInteraction();
    now = now.add(const Duration(minutes: 59));
    expect(activity.expired, isFalse);
    now = now.add(const Duration(minutes: 1));
    expect(activity.expired, isTrue);
  });

  test('input after expiry does not revive the login and is reported', () {
    var reports = 0;
    void listener() => reports += 1;
    activity.addListener(listener);
    addTearDown(() => activity.removeListener(listener));

    now = now.add(const Duration(hours: 1));
    activity.recordInteraction();
    activity.recordInteraction();
    expect(activity.expired, isTrue);
    expect(reports, 1);

    activity.startSession();
    expect(activity.expired, isFalse);
  });

  test('only requests started in the background are marked', () async {
    expect(UserActivity.headersFor({'A': 'b'}), {'A': 'b'});
    final headers = await UserActivity.runInBackground(() async {
      await Future<void>.delayed(Duration.zero);
      return UserActivity.headersFor({'A': 'b'});
    });
    expect(headers, {
      'A': 'b',
      UserActivity.headerName: UserActivity.backgroundValue,
    });
    expect(UserActivity.inBackground, isFalse);
  });
}
