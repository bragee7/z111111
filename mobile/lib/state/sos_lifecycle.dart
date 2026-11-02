/// Shared SOS lifecycle vocabulary.
///
/// The persisted strings in [SosExecutor] are the single source of truth and
/// are consumed by the native PowerGuardService/alarm activity, so they are
/// intentionally kept stable. This helper only maps them to lifecycle
/// semantics and implements the cancellation fence used by Dart + UI:
///
/// - IDLE      -> `idle` / `listening`
/// - ACTIVATING-> `countdown` (5s cancel window) / `cancelWindow` (legacy)
/// - ACTIVE    -> `recording` / `sending`
/// - CANCELLING-> `command == 'cancel'` is still in flight
/// - CANCELLED -> session id matches the persisted cancelled-session fence
/// - FAILED    -> `idle` after a failed send (with evidence kept)
/// - DELIVERED -> `sent` is terminal; tracking continues by case id
class SosLifecycle {
  SosLifecycle._();

  static const idle = 'idle';
  static const listening = 'listening';
  static const cancelWindow = 'cancelWindow';
  static const countdown = 'countdown';
  static const recording = 'recording';
  static const sending = 'sending';
  static const sent = 'sent';

  /// States in which an SOS session owns timers, the microphone, the camera
  /// or an in-flight submit.
  static const Set<String> activeStates = {
    cancelWindow,
    countdown,
    recording,
    sending,
  };

  static bool isActiveState(String? state) =>
      activeStates.contains((state ?? '').trim());

  /// True when the given session has been cancelled.
  ///
  /// The session-id comparison is authoritative whenever an id exists: a new
  /// session always gets a new id, so it can never match an old fence even if
  /// its timestamps overlap. The command/timestamp fallback only exists for
  /// legacy snapshots written before session ids were introduced.
  static bool isCancelledSession({
    String? sessionId,
    String? cancelledSessionId,
    String? command,
    int? startedAt,
    int? cancelledAt,
  }) {
    final sid = (sessionId ?? '').trim();
    final cid = (cancelledSessionId ?? '').trim();
    if (sid.isNotEmpty) {
      return cid.isNotEmpty && sid == cid;
    }
    if ((command ?? '').trim() == 'cancel') return true;
    final started = startedAt ?? 0;
    final cancelled = cancelledAt ?? 0;
    if (cancelled <= 0) return false;
    return started <= 0 || cancelled >= started;
  }
}
