import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../services/voice_guard_service.dart';
import '../state/auth_provider.dart';
import 'login_screen.dart';
import 'user_dashboard_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  String? _status;
  bool _canRetry = false;
  bool _navigated = false;
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    // Read before any async gap so the context use is synchronous.
    final auth = context.read<AuthProvider>();
    final attempt = ++_attempt;
    if (mounted) {
      setState(() {
        _status = null;
        _canRetry = false;
      });
    }
    await VoiceGuardService.flog('splash', '_restore started');
    try {
      await auth.restoreSession().timeout(const Duration(seconds: 15));
    } on TimeoutException catch (e) {
      await VoiceGuardService.flog(
          'splash', 'restoreSession TIMEOUT (15s): $e');
      // restoreSession may still complete in the background and preserve
      // the cached session; fall through to the authenticated check below.
    } catch (e) {
      await VoiceGuardService.flog('splash', 'restoreSession FAILED/hung: $e');
    }
    if (!mounted || attempt != _attempt || _navigated) {
      return;
    }
    await VoiceGuardService.flog(
        'splash', '_restore done, authenticated=${auth.isAuthenticated}');
    if (!mounted || attempt != _attempt || _navigated) {
      await VoiceGuardService.flog(
          'splash', 'ABORT: splash unmounted before nav, no route pushed');
      return;
    }

    await VoiceGuardService.flog('splash',
        'navigating, authenticated=${auth.isAuthenticated} role=${auth.user?.role}');
    try {
      if (auth.isAuthenticated) {
        // Brief signal when we fell back to the cached session.
        final fallback = auth.restoreError;
        if (fallback != null && mounted && attempt == _attempt) {
          setState(() {
            _status = fallback;
            _canRetry = false;
          });
          await Future<void>.delayed(const Duration(milliseconds: 900));
          if (!mounted || attempt != _attempt || _navigated) return;
        }
        if (auth.user?.role == 'police') {
          await auth.logout();
          if (!mounted || attempt != _attempt || _navigated) return;
          // Mobile client is user-only: a police session is logged out
          // and routed to login instead of the dashboard.
          _goTo(const LoginScreen());
          await VoiceGuardService.flog('splash', 'pushReplacement issued');
          return;
        }
        _goTo(const UserDashboardScreen());
      } else {
        final msg = auth.restoreError ??
            'Unable to restore session. Please log in.';
        if (mounted && attempt == _attempt) {
          setState(() {
            _status = msg;
            _canRetry = true;
          });
        }
        await VoiceGuardService.flog('splash', 'restore failed: $msg');
        // Brief accurate status before auto-routing to login (no new screens).
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        if (!mounted || attempt != _attempt || _navigated) return;
        _goTo(const LoginScreen());
      }
      await VoiceGuardService.flog('splash', 'pushReplacement issued');
    } catch (e) {
      await VoiceGuardService.flog('splash', 'NAV FAILED: $e');
    }
  }

  void _goTo(Widget page) {
    if (!mounted || _navigated) return;
    _navigated = true;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => page),
    );
  }

  Future<void> _retry() async {
    if (_navigated) return;
    await _restore();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.gray900,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.shield,
                color: AppColors.emergencyRed, size: 72),
            const SizedBox(height: 16),
            const Text(
              'ZELDA',
              style: TextStyle(
                color: AppColors.emergencyRed,
                fontSize: 32,
                fontWeight: FontWeight.w800,
                letterSpacing: 6,
              ),
            ),
            const Text(
              'Women Safety Guardian',
              style: TextStyle(color: AppColors.gray400, fontSize: 13),
            ),
            const SizedBox(height: 32),
            if (!_canRetry)
              const CircularProgressIndicator(
                color: AppColors.emergencyRed,
                strokeWidth: 3,
              ),
            if (_status != null) ...[
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  _status!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppColors.gray400, fontSize: 13),
                ),
              ),
            ],
            if (_canRetry) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: _retry,
                child: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
