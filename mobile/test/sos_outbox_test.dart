import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zelda_guardian/models/sos_case.dart';
import 'package:zelda_guardian/services/sos_outbox.dart';
import 'package:zelda_guardian/services/sos_service.dart';

class _FakeSosService extends SosService {
  _FakeSosService({this.existing = const <SosCase>[]});

  final List<SosCase> existing;
  int createCalls = 0;
  String? lastNotes;

  @override
  Future<List<SosCase>> getCases() async => existing;

  @override
  Future<SosCase> createCase({
    required String videoPath,
    required String audioPath,
    required String locationLink,
    required String latitude,
    required String longitude,
    required String notes,
  }) async {
    createCalls++;
    lastNotes = notes;
    return SosCase(
      id: 'created-1',
      userId: 'user-1',
      status: 'Pending',
      notes: notes,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'auth_user': jsonEncode(<String, String>{
        'id': 'user-1',
        'name': 'Test User',
        'email': 'test@example.com',
        'role': 'user',
      }),
    });
    temp = await Directory.systemTemp.createTemp('zelda_sos_outbox_test_');
    SosOutbox.baseDirectoryOverride = () async => temp;
    SosOutbox.tokenProviderOverride = () async => 'test-token';
  });

  tearDown(() async {
    SosOutbox.baseDirectoryOverride = null;
    SosOutbox.tokenProviderOverride = null;
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } catch (_) {}
  });

  Future<PendingSosAlert?> enqueue({
    String sessionId = 'session-1',
    String videoPath = '',
    int? createdAtMs,
  }) {
    return SosOutbox.enqueue(
      sessionId: sessionId,
      notes: 'SOS Alert (test)',
      latitude: '13.0827',
      longitude: '80.2707',
      locationLink: 'https://maps.google.com/?q=13.0827,80.2707',
      videoPath: videoPath,
      audioPath: '',
      source: 'test',
      createdAtMs: createdAtMs,
    );
  }

  test('enqueue copies evidence and is idempotent per session', () async {
    final source = File('${temp.path}/camera-cache.mp4');
    await source.writeAsBytes(<int>[1, 2, 3, 4]);

    final first = (await enqueue(videoPath: source.path))!;
    expect(first, isNotNull);
    expect(await SosOutbox.pendingCount(), 1);
    expect(first.reference, startsWith('ZELDA-'));
    expect(first.notesWithReference, contains(first.reference));
    expect(first.videoPath, isNot(source.path));
    expect(await File(first.videoPath).exists(), isTrue);

    final duplicate = await enqueue(videoPath: source.path);
    expect(duplicate!.id, first.id);
    expect(await SosOutbox.pendingCount(), 1);
  });

  test('pending survives a JSON round trip with all fields intact', () async {
    final alert = (await enqueue())!;
    final restored = PendingSosAlert.fromJson(
      jsonDecode(jsonEncode(alert.toJson())),
    );

    expect(restored.id, alert.id);
    expect(restored.sessionId, alert.sessionId);
    expect(restored.userId, 'user-1');
    expect(restored.notes, alert.notes);
    expect(restored.latitude, alert.latitude);
    expect(restored.longitude, alert.longitude);
    expect(restored.locationLink, alert.locationLink);
    expect(restored.source, alert.source);
    expect(restored.createdAtMs, alert.createdAtMs);
    expect(restored.attempts, alert.attempts);
    expect(restored.nextAttemptAtMs, alert.nextAttemptAtMs);
  });

  test('remove deletes the alert and its private media', () async {
    final source = File('${temp.path}/clip.mp4');
    await source.writeAsBytes(<int>[9, 9, 9]);
    final alert = (await enqueue(videoPath: source.path))!;
    final mediaDir = File(alert.videoPath).parent;

    expect(await mediaDir.exists(), isTrue);
    await SosOutbox.remove(alert.id);

    expect(await SosOutbox.pendingCount(), 0);
    expect(await mediaDir.exists(), isFalse);
  });

  test('expired alerts are discarded when a new alert is queued', () async {
    final old = await enqueue(
      sessionId: 'old',
      createdAtMs: DateTime.now()
          .subtract(const Duration(hours: 25))
          .millisecondsSinceEpoch,
    );
    expect(old, isNotNull);

    await enqueue(sessionId: 'new');
    expect(await SosOutbox.pendingCount(), 1);
    final pending = await SosOutbox.pending();
    expect(pending.single.sessionId, 'new');
  });

  test('retry without a token leaves the alert queued', () async {
    SosOutbox.tokenProviderOverride = () async => null;
    await enqueue();
    final delivered = await SosOutbox.retryPending();
    expect(delivered, isEmpty);
    expect(await SosOutbox.pendingCount(), 1);
  });

  Future<void> makeDue() async {
    final alert = (await SosOutbox.pending()).single;
    final prefs = await SharedPreferences.getInstance();
    final key = 'zelda_sos_outbox_v1_${alert.id}';
    final map = jsonDecode(prefs.getString(key)!) as Map<String, dynamic>;
    map['nextAttemptAtMs'] = 0;
    await prefs.setString(key, jsonEncode(map));
  }

  test(
    'a due alert is sent with its reference and removed from the queue',
    () async {
      await enqueue();
      await makeDue();
      final fake = _FakeSosService();

      final delivered = await SosOutbox.retryPending(service: fake);

      expect(fake.createCalls, 1);
      expect(fake.lastNotes, contains('Ref: ZELDA-'));
      expect(delivered.single.id, 'created-1');
      expect(await SosOutbox.pendingCount(), 0);
    },
  );

  test(
    'a retry recovers a case that was created before the response was lost',
    () async {
      final alert = (await enqueue())!;
      await makeDue();
      final fake = _FakeSosService(
        existing: <SosCase>[
          SosCase(
            id: 'existing-1',
            userId: 'user-1',
            status: 'Pending',
            notes: alert.notesWithReference,
          ),
        ],
      );

      final delivered = await SosOutbox.retryPending(service: fake);

      expect(fake.createCalls, 0);
      expect(delivered.single.id, 'existing-1');
      expect(await SosOutbox.pendingCount(), 0);
    },
  );

  test('an alert is not sent after a different user logs in', () async {
    await enqueue();
    await makeDue();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'auth_user',
      jsonEncode(<String, String>{
        'id': 'user-2',
        'name': 'Other User',
        'email': 'other@example.com',
        'role': 'user',
      }),
    );
    final fake = _FakeSosService();

    final delivered = await SosOutbox.retryPending(service: fake);

    expect(delivered, isEmpty);
    expect(fake.createCalls, 0);
    expect(await SosOutbox.pendingCount(), 1);
  });
}
