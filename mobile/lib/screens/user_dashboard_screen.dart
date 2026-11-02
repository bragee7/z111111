import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../core/theme.dart';
import '../core/widgets.dart';
import '../models/emergency_contact.dart';
import '../services/power_sos_service.dart';
import '../services/voice_guard_service.dart';
import '../state/auth_provider.dart';
import '../state/contacts_provider.dart';
import '../state/police_stations_provider.dart';
import '../state/sos_controller.dart';
import '../widgets/cancel_sos_button.dart';
import 'alerts_history_screen.dart';

class UserDashboardScreen extends StatefulWidget {
  const UserDashboardScreen({super.key});

  @override
  State<UserDashboardScreen> createState() => _UserDashboardScreenState();
}

class _UserDashboardScreenState extends State<UserDashboardScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _glowController;
  late final Animation<double> _glow;

  bool _showAddContact = false;
  String? _editingContactId;
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  String _relation = '';
  int _priority = 1;

  static const _relations = ['Parent', 'Spouse', 'Sibling', 'Friend', 'Colleague', 'Other'];
  static const _priorities = [1, 2, 3, 4, 5];

  @override
  void initState() {
    super.initState();
    VoiceGuardService.flog('route', 'dashboard shown');
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _glow = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _boot();
    });
  }

  /// Ordered boot: await controller init (prefs/services read) BEFORE the
  /// voice auto-start check, so the check sees live state instead of stale
  /// defaults. No SOS trigger/countdown/cancel/recording/send path changed.
  Future<void> _boot() async {
    try {
      await context.read<SosController>().init();
    } catch (_) {}
    if (!mounted) return;
    await _resyncSwitches();
    if (!mounted) return;
    // ignore: use_build_context_synchronously
    context.read<ContactsProvider>().fetchContacts();
    await _maybeAutoStartVoice();
    await VoiceGuardService.consumePendingTrigger();
  }

  /// Resync switch UI from actual prefs/services state. Power has no status
  /// stream, so a stale controller value (e.g. Off while pref is true after
  /// an early-returned init) is corrected via the existing setter (idempotent
  /// pref + native write, no SOS flow touched). Voice is read-only here: ask
  /// the live engine to re-emit running state and let the controller's
  /// statusStream listener correct the toggle — never start/stop here.
  Future<void> _resyncSwitches() async {
    try {
      // Re-assert FGS mic promotion on every foreground return (init +
      // resume): a service auto-started while backgrounded (e.g. after a
      // reboot) runs UNPROMOTED with its mic muted to zeros until something
      // promotes it. Idempotent, silent on failure (BG dead or backgrounded).
      VoiceGuardService.serviceInvoke('promote_to_foreground');
      final actualPower = await PowerSosService.isEnabled();
      if (!mounted) return;
      // ignore: use_build_context_synchronously
      final sos = context.read<SosController>();
      if (sos.powerSosEnabled != actualPower) {
        await VoiceGuardService.flog(
          'dashboard',
          'resync power switch UI: controller=${sos.powerSosEnabled} actual=$actualPower',
        );
        await sos.setPowerSosEnabled(actualPower);
      }
      // Voice toggle self-corrects via SosController's statusStream; just
      // re-query so a pre-subscribe ENGINE-UP is not lost on resume.
      VoiceGuardService.serviceInvoke('query_status');
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resyncSwitches();
    }
  }

  /// Presentation-layer copy fix: the controller/executor report a generic
  /// "check your connection" string for ALL send failures, including server
  /// 5xx where the phone's connection is fine. Rewrite to neutral wording
  /// that is accurate for both cases. Same AppBanner widget, no flow change.
  String _displayError(String raw) {
    if (raw.contains('check your connection')) {
      return 'Could not send emergency alert. Please try again. '
          'If it keeps failing, check your connection or try again later.';
    }
    return raw;
  }

  Future<void> _maybeAutoStartVoice() async {
    final user = context.read<AuthProvider>().user;
    if (user == null || user.role == 'police') return;
    // Heal ACTUAL state, not just the flag: the engine may be dead while the
    // flag reads ON (e.g. logout cleared prefs), or the flag may be stale
    // while the engine runs. The statusStream listener self-corrects the flag
    // when running, so only a dead engine needs action here.
    final running = await VoiceGuardService.isRunning();
    if (!mounted) return;
    final rawPref = await VoiceGuardService.getEnabledPrefRaw();
    if (!mounted) return;
    // ignore: use_build_context_synchronously
    final controllerOn = context.read<SosController>().voiceEnabled;
    await VoiceGuardService.flog('dashboard',
        'auto-start check: running=$running rawPref=$rawPref flag=$controllerOn');
    if (running) {
      // Heal: a live isolate may be engine-down (a post-stop reboot lands in
      // STANDBY and never boots the engine). Boot unless explicitly off; the
      // handler no-ops (re-affirms status) when the engine is already up.
      if (rawPref == null || rawPref) {
        await VoiceGuardService.flog('dashboard',
            'auto-start: service alive, requesting promote + engine boot check');
        // Promote FIRST: an unpromoted service (reboot auto-start in
        // background) has its mic muted to zeros; boot_engine alone cannot
        // revive capture. Dashboard init runs foreground ⇒ allowed.
        VoiceGuardService.serviceInvoke('promote_to_foreground');
        VoiceGuardService.serviceInvoke('boot_engine');
      }
      return;
    }
    // Start unless the user EXPLICITLY disabled voice (pref false AND flag
    // off). Covers fresh install (null), login-restore (true), and the
    // stale-flag heal case (flag on, engine dead).
    if (rawPref == null || rawPref || controllerOn) {
      final mic = await Permission.microphone.request();
      await Permission.notification.request();
      if (!mounted) return;
      if (mic.isGranted) {
        await context.read<SosController>().setVoiceEnabled(true);
      } else if (await VoiceGuardService.wasEnabled()) {
        await VoiceGuardService.restartIfNeeded();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _glowController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  /// Stashes the EFFECTIVE protection state before logout clears it, so
  /// login can restore the user's choice (fresh installs default to ON).
  Future<void> _stashProtectionPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final voiceRaw = await VoiceGuardService.getEnabledPrefRaw();
      await prefs.setBool(VoiceGuardService.preLogoutKey, voiceRaw ?? true);
      await prefs.setBool(
          PowerSosService.preLogoutKey, await PowerSosService.isEnabled());
    } catch (_) {}
  }

  Future<void> _handleLogout(BuildContext context) async {
    final sos = context.read<SosController>();
    final auth = context.read<AuthProvider>();
    await _stashProtectionPrefs();
    await sos.setVoiceEnabled(false);
    await sos.setPowerSosEnabled(false);
    await auth.logout();
    if (context.mounted) {
      Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
    }
  }

  Future<void> _openMaps(String link) async {
    final uri = Uri.parse(link);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _toggleVoice(SosController sos, bool enabled) async {
    try {
      await sos.setVoiceEnabled(enabled);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Voice protection error: $e')),
      );
    }
  }

  Future<void> _togglePowerSos(SosController sos, bool enabled) async {
    try {
      await sos.setPowerSosEnabled(enabled);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Power-button SOS error: $e')),
      );
    }
  }

  void _resetContactForm() {
    _nameController.clear();
    _phoneController.clear();
    _emailController.clear();
    _relation = '';
    _priority = 1;
    setState(() {
      _showAddContact = false;
      _editingContactId = null;
    });
  }

  void _startAddContact() {
    _nameController.clear();
    _phoneController.clear();
    _emailController.clear();
    _relation = '';
    _priority = 1;
    setState(() {
      _showAddContact = true;
      _editingContactId = null;
    });
  }

  void _startEdit(EmergencyContact contact) {
    _nameController.text = contact.name;
    _phoneController.text = contact.phone;
    _emailController.text = contact.email;
    _relation = contact.relation;
    _priority = contact.priority;
    setState(() {
      _showAddContact = false;
      _editingContactId = contact.id;
    });
  }

  Future<void> _saveContact(ContactsProvider contacts) async {
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();
    final email = _emailController.text.trim();
    if (name.isEmpty || phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name and phone are required')),
      );
      return;
    }
    try {
      if (_editingContactId != null) {
        await contacts.update(
          _editingContactId!,
          name: name,
          phone: phone,
          email: email,
          relation: _relation,
          priority: _priority,
        );
      } else {
        await contacts.add(
          name: name,
          phone: phone,
          email: email,
          relation: _relation,
          priority: _priority,
        );
      }
      if (mounted) _resetContactForm();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save contact: $e')),
      );
    }
  }

  Future<void> _deleteContact(ContactsProvider contacts, String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Contact'),
        content: const Text('Are you sure you want to delete this contact?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      if (!mounted) return;
      try {
        await contacts.remove(id);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete contact: $e')),
        );
      }
    }
  }

  Future<void> _saveFile(String path, String label) async {
    final file = File(path);
    if (!await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Recording file not found on this device')),
      );
      return;
    }
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path, mimeType: 'video/mp4')],
        subject: 'ZELDA $label',
        text: 'ZELDA $label',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final sos = context.watch<SosController>();
    final contacts = context.watch<ContactsProvider>();
    final user = auth.user;

    return Scaffold(
      body: Column(
        children: [
          _buildNavbar(context, user?.name ?? '', user?.role ?? ''),
          Expanded(
            child: Container(
              decoration: const BoxDecoration(gradient: AppGradients.userDashboard),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 8),
                        const Text(
                          'Emergency Dashboard',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Welcome, ${user?.name ?? ''}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: AppColors.gray300),
                        ),
                        const SizedBox(height: 16),
                        if (sos.error.isNotEmpty) ...[
                          AppBanner(
                            message: _displayError(sos.error),
                            isError: true,
                            onDismiss: sos.dismissError,
                          ),
                        ],
                        if (sos.success.isNotEmpty) ...[
                          AppBanner(
                            message: sos.success,
                            onDismiss: sos.dismissSuccess,
                          ),
                        ],
                        _buildStatusCard(sos),
                        const SizedBox(height: 16),
                        _buildVoiceBanner(sos),
                        _buildPowerBanner(sos),
                        _buildCameraSelector(sos),
                        if (sos.isTracking) _buildTrackingBanner(sos),
                        const SizedBox(height: 8),
                        _buildSosButton(sos),
                        if (sos.locationLink.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          _buildLocationCard(sos),
                        ],
                        const SizedBox(height: 16),
                        _buildPoliceStationsCard(context),
                        const SizedBox(height: 16),
                        _buildContactsCard(context, contacts),
                        const SizedBox(height: 16),
                        _buildAlertsHistory(),
                        const SizedBox(height: 16),
                        _buildHowItWorks(),
                        const SizedBox(height: 16),
                        _buildVoicePhrasesSettings(),
                        if (sos.showPreview &&
                            (sos.recordedVideoPath != null ||
                                sos.recordedAudioPath != null))
                          _buildPreviewPanel(sos),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavbar(BuildContext context, String name, String role) {
    return Material(
      color: Colors.white,
      elevation: 4,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [AppColors.emergencyRed, AppColors.pink500],
                  ),
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.shield, color: Colors.white, size: 24),
              ),
              const SizedBox(width: 10),
              const Text(
                'Guardian',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: AppColors.gray800,
                ),
              ),
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.gray800,
                    ),
                  ),
                  Text(
                    role.isEmpty ? role : role[0].toUpperCase() + role.substring(1),
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.gray500,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: () => _handleLogout(context),
                style: TextButton.styleFrom(
                  backgroundColor: AppColors.gray100,
                  foregroundColor: AppColors.gray700,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                child: const Text('Logout', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusCard(SosController sos) {
    final (label, bg, fg, pulsing) = _statusStyle(sos.status);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.gray800,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Status',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              StatusPill(label: label, background: bg, foreground: fg, pulsing: pulsing),
            ],
          ),
          const SizedBox(height: 12),
          // One merged cancel view drives both statuses (cancelWindow is a
          // legacy mirror state only): a single 5s countdown, then recording.
          if (sos.status == SosStatus.cancelWindow ||
              sos.status == SosStatus.countdown)
            _buildCancelWindow(sos)
          else if (sos.status == SosStatus.recording)
            _buildRecording(sos)
          else if (sos.status == SosStatus.sending)
            _buildSending()
          else
            const SizedBox(height: 8),
        ],
      ),
    );
  }

  (String, Color, Color, bool) _statusStyle(SosStatus status) {
    switch (status) {
      case SosStatus.idle:
        return ('Idle', AppColors.gray700, AppColors.gray300, false);
      case SosStatus.listening:
        return ('Listening', AppColors.blue600, Colors.white, true);
      case SosStatus.cancelWindow:
        return ('Cancellable', AppColors.orange600, Colors.white, true);
      case SosStatus.countdown:
        return ('Countdown', AppColors.orange600, Colors.white, false);
      case SosStatus.recording:
        return ('Recording', AppColors.red600, Colors.white, true);
      case SosStatus.sending:
        return ('Sending', AppColors.orange600, Colors.white, false);
      case SosStatus.sent:
        return ('Sent', AppColors.green600, Colors.white, false);
    }
  }

  /// Zelda Emergency SOS cancel countdown — styled after the Android
  /// Emergency SOS reference: dark card, title, big live countdown in a
  /// coral ring, prominent red Cancel SOS button. The SOS is ALREADY
  /// triggered, so there is no "start" action anywhere here — only cancel.
  Widget _buildCancelWindow(SosController sos) {
    final seconds = sos.cancelTimer ?? sos.countdown ?? 0;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.red500, width: 1.5),
      ),
      child: Column(
        children: [
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.sos, color: AppColors.red500, size: 28),
              SizedBox(width: 10),
              Text(
                'SOS Alert Active',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Your emergency alert has been triggered.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: AppColors.gray300),
          ),
          const SizedBox(height: 6),
          const Text(
            'Emergency assistance will be requested when the countdown ends.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: AppColors.gray400),
          ),
          const SizedBox(height: 12),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Your phone will:',
              style: TextStyle(fontSize: 16, color: AppColors.gray300),
            ),
          ),
          const SizedBox(height: 6),
          const Row(
            children: [
              Icon(Icons.check, color: Colors.green, size: 20),
              SizedBox(width: 10),
              Text(
                'Send SOS + record evidence',
                style: TextStyle(fontSize: 17, color: Colors.white),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Container(
            width: 210,
            height: 210,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: const Color(0xFFEF6C5B),
                width: 8,
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              '$seconds',
              style: const TextStyle(
                fontSize: 84,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'SOS will be sent in ${seconds}s',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15, color: AppColors.gray300),
          ),
          const SizedBox(height: 20),
          // Prominent, always-visible TAP-to-cancel control — the countdown
          // cannot be dismissed by gesture or rebuild; only this button
          // cancels, and it ignores taps while a cancel request is in flight.
          CancelSosButton(onPressed: sos.cancelSOS, busy: sos.isCancelling),
        ],
      ),
    );
  }

  Widget _buildRecording(SosController sos) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.fiber_manual_record, color: AppColors.red500, size: 20),
              SizedBox(width: 6),
              Text(
                'RECORDING',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColors.red500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${sos.recordingTime}s',
            style: const TextStyle(
              fontSize: 64,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Recording your emergency situation...',
            style: TextStyle(color: AppColors.gray400),
          ),
          const SizedBox(height: 16),
          // Cancel affordance during recording: the executor honors
          // command=cancel in every recording phase (poll, app-report,
          // native-recording) and cancelSOS() stops the camera for the
          // local path, so this is a pure UI addition — no lifecycle change.
          // Same shared tap-to-cancel control as the countdown card.
          CancelSosButton(
            onPressed: () => sos.cancelSOS(),
            busy: sos.isCancelling,
          ),
        ],
      ),
    );
  }

  Widget _buildSending() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          SizedBox(
            width: 56,
            height: 56,
            child: CircularProgressIndicator(
              strokeWidth: 4,
              color: AppColors.orange500,
            ),
          ),
          SizedBox(height: 16),
          Text(
            'Sending emergency alert...',
            style: TextStyle(fontSize: 18, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _buildVoiceBanner(SosController sos) {
    return ValueListenableBuilder<bool>(
      valueListenable: VoiceGuardService.micDegraded,
      builder: (context, micDegraded, _) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: (micDegraded ? Colors.amber.shade900 : AppColors.green900)
                .withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: micDegraded ? Colors.amber : AppColors.green500,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  sos.voiceEnabled
                      ? (micDegraded
                          ? 'Voice detection paused - open ZELDA to restore microphone access'
                          : 'Voice Protection Active - Listening for "help me"')
                      : '24/7 Voice Protection Off',
                  style: const TextStyle(
                      color: AppColors.green400, fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              Switch(
                value: sos.voiceEnabled,
                activeThumbColor: AppColors.green500,
                onChanged: (v) => _toggleVoice(sos, v),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPowerBanner(SosController sos) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.gray800,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: sos.powerSosEnabled ? AppColors.green500 : AppColors.gray500,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              sos.powerSosEnabled
                  ? 'Power-button SOS On - Press power 3x in 6s'
                  : 'Power-button SOS Off',
              style: const TextStyle(color: AppColors.green400, fontSize: 13),
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: sos.powerSosEnabled,
            activeThumbColor: AppColors.green500,
            onChanged: (v) => _togglePowerSos(sos, v),
          ),
        ],
      ),
    );
  }

  Widget _buildCameraSelector(SosController sos) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.gray800,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.videocam_outlined, color: AppColors.purple700, size: 20),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Recording Camera',
                style: TextStyle(color: AppColors.gray300, fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
            _cameraOption(sos, CameraLensDirection.back, 'Back', Icons.videocam_outlined),
            const SizedBox(width: 8),
            _cameraOption(sos, CameraLensDirection.front, 'Front', Icons.camera_front_outlined),
          ],
        ),
      ),
    );
  }

  Widget _cameraOption(
    SosController sos,
    CameraLensDirection lens,
    String label,
    IconData icon,
  ) {
    final selected = sos.selectedLens == lens;
    return InkWell(
      onTap: () => sos.setCameraLens(lens),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.purple600 : AppColors.gray900,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppColors.purple700 : AppColors.gray700,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: selected ? Colors.white : AppColors.gray400),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : AppColors.gray400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrackingBanner(SosController sos) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.blue900.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.blue400,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: const Text(
              'Live Location Tracking Active - Updating every 30 seconds',
              style: TextStyle(color: AppColors.blue300, fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: sos.stopLocationTracking,
            child: const Text(
              'Stop',
              style: TextStyle(color: AppColors.blue200, decoration: TextDecoration.underline),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSosButton(SosController sos) {
    return AnimatedBuilder(
      animation: _glow,
      builder: (context, _) {
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: AppColors.red500.withValues(alpha: _glow.value * 0.7),
                blurRadius: 30 * _glow.value,
                spreadRadius: 2 * _glow.value,
              ),
            ],
          ),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: sos.isBusy ? null : sos.triggerSOS,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 44),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.favorite, color: Colors.white, size: 56),
                  const SizedBox(height: 12),
                  const Text(
                    'SEND SOS ALERT',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  if (sos.isBusy) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'Please wait...',
                      style: TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPoliceStationsCard(BuildContext context) {
    final ps = context.watch<PoliceStationsProvider>();
    final count = ps.all.isEmpty ? '—' : '${ps.all.length}';
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.policeBlue,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Police Stations',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$count stations',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Find the nearest police station, see the route, and get '
            'turn-by-turn directions to the control room.',
            style: TextStyle(color: AppColors.gray300, fontSize: 13),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.pushNamed(context, '/police-stations');
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: AppColors.policeBlue,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: const Icon(Icons.map_outlined, size: 19),
                  label: const Text(
                    'Open station map',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLocationCard(SosController sos) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.gray800,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Your Location',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Colors.white),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.location_on_outlined, color: AppColors.green500, size: 24),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: () => _openMaps(sos.locationLink),
                child: const Text(
                  'Open in Google Maps',
                  style: TextStyle(
                    color: AppColors.blue400,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ),
          if (sos.location != null) ...[
            const SizedBox(height: 8),
            Text(
              'Lat: ${sos.location!.latitude.toStringAsFixed(6)}, Lng: ${sos.location!.longitude.toStringAsFixed(6)}',
              style: const TextStyle(color: AppColors.gray400, fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildContactsCard(BuildContext context, ContactsProvider contacts) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.gray800,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.group_outlined, color: AppColors.blue400, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Emergency Contacts',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Colors.white),
                ),
              ),
              ElevatedButton(
                onPressed: _startAddContact,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.blue600,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, size: 18),
                    SizedBox(width: 4),
                    Text('Add Contact', style: TextStyle(fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_showAddContact) _buildContactForm(contacts),
          if (contacts.error.isNotEmpty) ...[
            AppBanner(
              message: contacts.error,
              isError: true,
              onDismiss: contacts.dismissError,
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: OutlinedButton.icon(
                onPressed: contacts.isLoading ? null : contacts.fetchContacts,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Retry'),
              ),
            ),
          ],
          if (contacts.isLoading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: LoadingSpinner(color: AppColors.blue400, size: 32),
            )
          else if (contacts.contacts.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No emergency contacts added yet.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.gray500, fontSize: 13),
              ),
            )
          else
            ...contacts.contacts.map((c) => _buildContactTile(contacts, c)),
          const SizedBox(height: 8),
          const Text(
            'Your emergency contacts will be notified via email when you trigger an SOS alert.',
            style: TextStyle(color: AppColors.gray600, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildContactForm(ContactsProvider contacts) {
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.gray900,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _nameController,
            style: const TextStyle(color: AppColors.gray900),
            decoration: const InputDecoration(
              labelText: 'Full Name *',
              filled: true,
              fillColor: Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            style: const TextStyle(color: AppColors.gray900),
            decoration: const InputDecoration(
              labelText: 'Phone Number *',
              filled: true,
              fillColor: Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            style: const TextStyle(color: AppColors.gray900),
            decoration: const InputDecoration(
              labelText: 'Email (for SOS alerts)',
              filled: true,
              fillColor: Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _relation.isEmpty ? null : _relation,
            dropdownColor: Colors.white,
            style: const TextStyle(color: AppColors.gray900),
            decoration: const InputDecoration(
              labelText: 'Relation',
              filled: true,
              fillColor: Colors.white,
            ),
            items: _relations
                .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                .toList(),
            onChanged: (v) => setState(() => _relation = v ?? ''),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: _priority,
            decoration: const InputDecoration(
              labelText: 'Priority (1 = highest)',
              filled: true,
              fillColor: Colors.white,
            ),
            items: _priorities
                .map((p) => DropdownMenuItem(value: p, child: Text('P$p')))
                .toList(),
            onChanged: (v) => setState(() => _priority = v ?? 1),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _saveContact(contacts),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.green600,
                  ),
                  child: const Text('Save Contact'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: _resetContactForm,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.gray700,
                  ),
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildContactTile(ContactsProvider contacts, EmergencyContact contact) {
    final editing = _editingContactId == contact.id;
    if (editing) {
      return Container(
        padding: const EdgeInsets.all(12),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: AppColors.gray900,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _nameController,
              style: const TextStyle(color: AppColors.gray900),
              decoration: const InputDecoration(
                labelText: 'Full Name',
                filled: true,
                fillColor: Colors.white,
              ),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              style: const TextStyle(color: AppColors.gray900),
              decoration: const InputDecoration(
                labelText: 'Phone',
                filled: true,
                fillColor: Colors.white,
              ),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              style: const TextStyle(color: AppColors.gray900),
              decoration: const InputDecoration(
                labelText: 'Email',
                filled: true,
                fillColor: Colors.white,
              ),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _relation.isEmpty ? null : _relation,
              dropdownColor: Colors.white,
              style: const TextStyle(color: AppColors.gray900),
              decoration: const InputDecoration(
                labelText: 'Relation',
                filled: true,
                fillColor: Colors.white,
              ),
              items: _relations
                  .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                  .toList(),
              onChanged: (v) => setState(() => _relation = v ?? ''),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _priority,
              decoration: const InputDecoration(
                labelText: 'Priority (1 = highest)',
                filled: true,
                fillColor: Colors.white,
              ),
              items: _priorities
                  .map((p) => DropdownMenuItem(value: p, child: Text('P$p')))
                  .toList(),
              onChanged: (v) => setState(() => _priority = v ?? 1),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => _saveContact(contacts),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.green600,
                    ),
                    child: const Text('Save'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _resetContactForm,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.gray700,
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.gray900,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          InitialsAvatar(name: contact.name, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        contact.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (contact.relation.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.blue900,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          contact.relation,
                          style: const TextStyle(color: AppColors.blue300, fontSize: 11),
                        ),
                      ),
                    ],
                    if (contact.priority > 1) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.amber900,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          'P${contact.priority}',
                          style: const TextStyle(color: AppColors.amber300, fontSize: 11),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  contact.phone,
                  style: const TextStyle(color: AppColors.gray400, fontSize: 13),
                ),
                if (contact.email.isNotEmpty)
                  Text(
                    contact.email,
                    style: const TextStyle(color: AppColors.gray500, fontSize: 11),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Edit',
            onPressed: () => _startEdit(contact),
            icon: const Icon(Icons.edit_outlined, color: AppColors.gray300, size: 20),
          ),
          IconButton(
            tooltip: 'Delete',
            onPressed: () => _deleteContact(contacts, contact.id),
            icon: const Icon(Icons.delete_outline, color: AppColors.red300, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _buildAlertsHistory() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AlertsHistoryScreen()),
          );
        },
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.gray800,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.blue900,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.history_outlined,
                  color: AppColors.blue400,
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Text(
                  'My Alerts',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.gray600, size: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHowItWorks() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.gray800,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'How It Works',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Colors.white),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _howItWorksStep('1', AppColors.blue600, 'Voice recognition is always active in background'),
              ),
              Expanded(
                child: _howItWorksStep('2', AppColors.orange600, 'Say "help me" — SOS fires even with the app closed'),
              ),
              Expanded(
                child: _howItWorksStep('3', AppColors.red600, '30-second recording will be sent to police'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildVoicePhrasesSettings() {
    return const _TriggerWordsCard();
  }

  Widget _howItWorksStep(String number, Color color, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Text(
              number,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.gray300, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewPanel(SosController sos) {
    final videoPath = sos.recordedVideoPath;
    final audioPath = sos.recordedAudioPath;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.gray800,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle_outline, color: AppColors.green500, size: 24),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Your Recorded Files',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
                ),
              ),
              IconButton(
                onPressed: sos.dismissPreview,
                icon: const Icon(Icons.close, color: AppColors.gray400),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (videoPath != null) ...[
            _VideoPreview(path: videoPath),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              onPressed: () => _saveFile(videoPath, 'Video Recording'),
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.purple600),
              icon: const Icon(Icons.download_outlined, size: 18),
              label: const Text('Download Video'),
            ),
            const SizedBox(height: 16),
          ],
          if (audioPath != null) ...[
            _AudioPreview(path: audioPath),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              onPressed: () => _saveFile(audioPath, 'Audio Recording'),
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.blue600),
              icon: const Icon(Icons.download_outlined, size: 18),
              label: const Text('Download Audio'),
            ),
          ],
          const SizedBox(height: 16),
          const Text(
            'Your recordings are automatically saved to this device. They are also sent to the police dashboard.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.gray500, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _TriggerWordsCard extends StatefulWidget {
  const _TriggerWordsCard();

  @override
  State<_TriggerWordsCard> createState() => _TriggerWordsCardState();
}

class _TriggerWordsCardState extends State<_TriggerWordsCard> {
  final _controller = TextEditingController();
  List<String> _words = const ['Help me'];
  bool _loading = true;
  bool _saving = false;
  String? _message;
  bool _messageOk = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final words = await VoiceGuardService.getTriggerWords();
    if (!mounted) return;
    setState(() {
      _words = words;
      _controller.text = words.join(', ');
      _loading = false;
    });
  }

  Future<void> _save() async {
    final parts = _controller.text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) {
      setState(() {
        _message = 'Enter at least one word.';
        _messageOk = false;
      });
      return;
    }
    setState(() {
      _saving = true;
      _message = null;
    });
    final result = await VoiceGuardService.setTriggerWords(parts);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _words = result.words;
      _controller.text = result.words.join(', ');
      _message = result.message;
      _messageOk = result.ok;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.gray800,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Trigger Words',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: Colors.white),
          ),
          const SizedBox(height: 4),
          Text(
            _loading
                ? 'Loading…'
                : 'Say ${_words.map((w) => '"$w"').join(' or ')} — SOS fires even with the app closed.',
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            enabled: !_loading && !_saving,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'help me',
              hintStyle: const TextStyle(color: Colors.grey),
              filled: true,
              fillColor: AppColors.gray900,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Separate multiple words with commas (max 3). Common English works best.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: (_loading || _saving) ? null : _save,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.green500,
              foregroundColor: Colors.white,
            ),
            child: _saving
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Save trigger word'),
          ),
          if (_message != null) ...[
            const SizedBox(height: 8),
            Text(
              _message!,
              style: TextStyle(
                fontSize: 13,
                color: _messageOk ? AppColors.green400 : Colors.orange,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _VideoPreview extends StatefulWidget {
  final String path;
  const _VideoPreview({required this.path});

  @override
  State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
  VideoPlayerController? _controller;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.path));
    _controller!.initialize().then((_) {
      if (!mounted) return;
      _controller!.setLooping(true);
      setState(() {});
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return Container(
        height: 160,
        decoration: BoxDecoration(
          color: AppColors.gray900,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: const LoadingSpinner(color: AppColors.purple600, size: 28),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(
        aspectRatio: controller.value.aspectRatio,
        child: Stack(
          alignment: Alignment.center,
          children: [
            VideoPlayer(controller),
            GestureDetector(
              onTap: () => setState(() {
                controller.value.isPlaying ? controller.pause() : controller.play();
              }),
              child: Container(
                color: Colors.black26,
                alignment: Alignment.center,
                child: Icon(
                  controller.value.isPlaying ? Icons.pause_circle : Icons.play_circle,
                  color: Colors.white,
                  size: 56,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AudioPreview extends StatefulWidget {
  final String path;
  const _AudioPreview({required this.path});

  @override
  State<_AudioPreview> createState() => _AudioPreviewState();
}

class _AudioPreviewState extends State<_AudioPreview> {
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<PlayerState>? _stateSub;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _stateSub = _player.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _playing = state == PlayerState.playing);
    });
    _player.setSourceDeviceFile(widget.path).then((_) {
      if (mounted) _player.resume();
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.gray900,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () async {
              if (_playing) {
                await _player.pause();
              } else {
                await _player.resume();
              }
            },
            icon: Icon(
              _playing ? Icons.pause : Icons.play_arrow,
              color: AppColors.blue300,
            ),
          ),
          const Text(
            'Audio Recording',
            style: TextStyle(color: AppColors.gray300, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
