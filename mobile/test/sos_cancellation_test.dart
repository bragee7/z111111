import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zelda_guardian/services/sos_executor.dart';
import 'package:zelda_guardian/state/sos_controller.dart';

/// Regression tests for the SOS cancellation lifecycle:
/// - one session-scoped, idempotent commit per session
/// - the persisted mirror, alarm handshake and pending triggers all cleared
/// - late/native snapshots for a cancelled session can never reopen the card
/// - a genuinely new session still works after a cancel
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('commitCancellation clears every session resource and stamps the fence',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      SosExecutor.stateKey: 'countdown',
      SosExecutor.remainingKey: 4,
      SosExecutor.sessionIdKey: 'sos_1_a',
      SosExecutor.commandKey: 'cancel',
      SosExecutor.nativeCommandKey: 'start_recording',
      SosExecutor.nativeDoneKey: true,
      SosExecutor.sendingAtKey: 123456,
      SosExecutor.alarmRequestKey: 999,
      SosExecutor.alarmHandledKey: 999,
      SosExecutor.pendingVoiceTriggerKey: 111,
      SosExecutor.pendingPowerTriggerKey: 112,
    });

    final ok = await SosExecutor.commitCancellation(reason: 'user cancel');

    expect(ok, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(SosExecutor.stateKey), 'listening');
    expect(prefs.getInt(SosExecutor.remainingKey), 0);
    expect(prefs.getString(SosExecutor.commandKey), '');
    expect(prefs.getString(SosExecutor.nativeCommandKey), 'stop');
    expect(prefs.getInt(SosExecutor.alarmRequestKey), 0);
    expect(prefs.getInt(SosExecutor.alarmHandledKey), 0);
    expect(prefs.containsKey(SosExecutor.sendingAtKey), isFalse);
    expect(prefs.containsKey(SosExecutor.nativeDoneKey), isFalse);
    expect(prefs.containsKey(SosExecutor.pendingVoiceTriggerKey), isFalse);
    expect(prefs.containsKey(SosExecutor.pendingPowerTriggerKey), isFalse);
    expect(prefs.getString(SosExecutor.cancelledSessionIdKey), 'sos_1_a');
    expect(prefs.getInt(SosExecutor.cancelledAtKey), greaterThan(0));
    expect(prefs.getString(SosExecutor.cancelReasonKey), 'user cancel');
  });

  test('repeated cancellation is idempotent and does not move the fence',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      SosExecutor.stateKey: 'countdown',
      SosExecutor.sessionIdKey: 'sos_1_a',
    });

    expect(await SosExecutor.commitCancellation(reason: 'user cancel'), isTrue);
    final prefs = await SharedPreferences.getInstance();
    final firstStamp = prefs.getInt(SosExecutor.cancelledAtKey);

    // A duplicate tap / duplicate native cancel must not create a new
    // transition or a new timestamp.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(
      await SosExecutor.commitCancellation(reason: 'alarm-activity cancel'),
      isTrue,
    );
    expect(prefs.getInt(SosExecutor.cancelledAtKey), firstStamp);
    expect(prefs.getString(SosExecutor.stateKey), 'listening');
    expect(prefs.getString(SosExecutor.cancelledSessionIdKey), 'sos_1_a');
  });

  test('a stale cancel cannot touch a newer active session', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      SosExecutor.stateKey: 'countdown',
      SosExecutor.remainingKey: 5,
      SosExecutor.sessionIdKey: 'sos_new',
      SosExecutor.cancelledSessionIdKey: 'sos_old',
      SosExecutor.cancelledAtKey: 1000,
    });

    final ok = await SosExecutor.commitCancellation(
      reason: 'user cancel',
      sessionId: 'sos_old',
    );

    expect(ok, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(SosExecutor.stateKey), 'countdown');
    expect(prefs.getInt(SosExecutor.remainingKey), 5);
    expect(prefs.getString(SosExecutor.sessionIdKey), 'sos_new');
    expect(prefs.getString(SosExecutor.cancelledSessionIdKey), 'sos_old');
    expect(prefs.getInt(SosExecutor.cancelledAtKey), 1000);
  });

  test('readSnapshot reports a cancelled session as fenced and inactive',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      SosExecutor.stateKey: 'countdown',
      SosExecutor.sessionIdKey: 'sos_1_a',
    });
    await SosExecutor.commitCancellation(reason: 'user cancel');

    final snap = await SosExecutor.readSnapshot();

    expect(snap['state'], 'listening');
    expect(snap['sessionId'], 'sos_1_a');
    expect(snap['sessionCancelled'], isTrue);
    expect(snap['cancelledSessionId'], 'sos_1_a');
    expect(snap['cancelReason'], 'user cancel');
  });

  testWidgets('cancelled session snapshot forces the controller to listening',
      (tester) async {
    final controller = SosController();

    controller.debugApplySnapshot(<String, Object?>{
      'state': 'countdown',
      'remaining': 5,
      'sessionId': 'sos_1_a',
      'sessionCancelled': true,
      'cancelled': true,
      'message': 'SOS cancelled',
    });

    expect(controller.status, SosStatus.listening);
    expect(controller.success, contains('cancelled'));

    await tester.pump(const Duration(seconds: 4));
    controller.dispose();
  });

  testWidgets('a genuinely new session still shows its countdown', (tester) async {
    final controller = SosController();

    controller.debugApplySnapshot(<String, Object?>{
      'state': 'countdown',
      'remaining': 5,
      'sessionId': 'sos_old',
      'sessionCancelled': true,
      'cancelled': true,
      'message': 'SOS cancelled',
    });
    expect(controller.status, SosStatus.listening);

    // Fresh trigger: new session id, no fence for it.
    controller.debugApplySnapshot(<String, Object?>{
      'state': 'countdown',
      'remaining': 5,
      'sessionId': 'sos_new',
      'sessionCancelled': false,
    });

    expect(controller.status, SosStatus.countdown);
    expect(controller.countdown, 5);

    await tester.pump(const Duration(seconds: 4));
    controller.dispose();
  });

  test('legacy snapshots without a session id use the timestamp fence',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      SosExecutor.stateKey: 'countdown',
      SosExecutor.startedAtKey: 1000,
      SosExecutor.cancelledAtKey: 2000,
    });

    final snap = await SosExecutor.readSnapshot();
    expect(snap['sessionId'], '');
    expect(snap['sessionCancelled'], isTrue);

    // An active state that started AFTER the cancel is not fenced.
    SharedPreferences.setMockInitialValues(<String, Object>{
      SosExecutor.stateKey: 'countdown',
      SosExecutor.startedAtKey: 3000,
      SosExecutor.cancelledAtKey: 2000,
    });
    final fresh = await SosExecutor.readSnapshot();
    expect(fresh['sessionCancelled'], isFalse);
  });

  test('beginLocalSession issues a new id that is not blocked by the old fence',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      SosExecutor.stateKey: 'listening',
      SosExecutor.sessionIdKey: 'sos_old',
      SosExecutor.cancelledSessionIdKey: 'sos_old',
      SosExecutor.cancelledAtKey: 1000,
      SosExecutor.pendingVoiceTriggerKey: 111,
      SosExecutor.pendingPowerTriggerKey: 112,
    });

    final id = await SosExecutor.beginLocalSession();

    expect(id, isNotEmpty);
    expect(id, isNot('sos_old'));
    expect(await SosExecutor.isCurrentSessionCancelled(), isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(SosExecutor.sessionIdKey), id);
    expect(prefs.getString(SosExecutor.commandKey), '');
    expect(prefs.containsKey(SosExecutor.pendingVoiceTriggerKey), isFalse);
    expect(prefs.containsKey(SosExecutor.pendingPowerTriggerKey), isFalse);
  });
}
