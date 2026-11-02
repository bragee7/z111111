import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Large, obvious, tap-to-cancel button shared by every SOS cancellation
/// surface (in-app countdown card, recording phase, and the native
/// lock-screen alarm activity mirrors the same visual language).
///
/// Replaces the old swipe-to-cancel interaction: a single tap cancels the
/// active SOS. While [busy] the button is disabled and shows a spinner so
/// repeated taps cannot issue duplicate cancellation requests.
class CancelSosButton extends StatelessWidget {
  const CancelSosButton({
    super.key,
    required this.onPressed,
    this.busy = false,
  });

  /// Invoked on tap. Never called while [busy] is true.
  final VoidCallback? onPressed;

  /// True while a cancellation request is in flight: the button shows
  /// "CANCELLING…" with a spinner and ignores further taps.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: busy ? null : onPressed,
        icon: busy
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : const Icon(Icons.close, color: Colors.white, size: 28),
        label: Text(
          busy ? 'CANCELLING…' : 'CANCEL SOS',
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.red600,
          disabledBackgroundColor: AppColors.red600.withValues(alpha: 0.6),
          disabledForegroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 18),
          minimumSize: const Size.fromHeight(64),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(40),
          ),
        ),
      ),
    );
  }
}
