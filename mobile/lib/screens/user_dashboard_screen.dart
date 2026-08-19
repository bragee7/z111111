import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../core/theme.dart';
import '../core/widgets.dart';
import '../models/emergency_contact.dart';
import '../services/voice_guard_service.dart';
import '../core/api_client.dart';
import '../state/auth_provider.dart';
import '../state/contacts_provider.dart';
import '../state/sos_controller.dart';
import 'alerts_history_screen.dart';

class UserDashboardScreen extends StatefulWidget {
  const UserDashboardScreen({super.key});

  @override
  State<UserDashboardScreen> createState() => _UserDashboardScreenState();
}

class _UserDashboardScreenState extends State<UserDashboardScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _glowController;
  late final Animation<double> _glow;

  bool _showAddContact = false;
  String? _editingContactId;
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  String _relation = '';
  int _priority = 1;
  List<String> _phrases = [];
  bool _phrasesLoading = true;
  final _phraseCtrl = TextEditingController();

  static const _relations = ['Parent', 'Spouse', 'Sibling', 'Friend', 'Colleague', 'Other'];
  static const _priorities = [1, 2, 3, 4, 5];

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _glow = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<SosController>().init();
      context.read<ContactsProvider>().fetchContacts();
      _maybeAutoStartVoice();
      _loadPhrases();
      VoiceGuardService.consumePendingTrigger();
    });
  }

  Future<void> _maybeAutoStartVoice() async {
    final user = context.read<AuthProvider>().user;
    if (user == null || user.role == 'police') return;
    if (context.read<SosController>().voiceEnabled) return;

    final mic = await Permission.microphone.request();
    await Permission.notification.request();
    if (!mounted) return;
    if (mic.isGranted) {
      await context.read<SosController>().setVoiceEnabled(true);
    } else if (await VoiceGuardService.wasEnabled()) {
      await VoiceGuardService.restartIfNeeded();
    }
  }

  Future<void> _loadPhrases() async {
    try {
      final res = await ApiClient.instance.get('preferences');
      final raw = res.data['voicePhrases'] as List?;
      final phrases = raw?.whereType<String>().map((p) => p.trim()).toList() ?? [];
      final next = phrases.isEmpty ? const ['help me'] : phrases;
      if (!mounted) return;
      setState(() {
        _phrases = next;
        _phrasesLoading = false;
      });
      VoiceGuardService.setKeywords(next);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _phrases = const ['help me'];
        _phrasesLoading = false;
      });
      VoiceGuardService.setKeywords(const ['help me']);
    }
  }

  Future<void> _savePhrases(List<String> next) async {
    try {
      await ApiClient.instance.put('preferences', {'voicePhrases': next});
      if (!mounted) return;
      setState(() => _phrases = List.of(next));
      VoiceGuardService.setKeywords(next);
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().contains('400') ? 'Invalid phrase. Check length (max 50 chars).' :
                  e.toString().contains('401') ? 'Session expired. Please log in again.' :
                  e.toString().contains('500') ? 'Server error. Try again.' :
                  'Could not save phrases. Check connection.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
      );
    }
  }

  void _addPhrase() {
    final text = _phraseCtrl.text.trim();
    if (text.isEmpty) return;
    if (_phrases.length >= 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Maximum 10 phrases allowed.')),
      );
      return;
    }
    if (_phrases.any((p) => p.toLowerCase() == text.toLowerCase())) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That phrase already exists.')),
      );
      return;
    }
    _phraseCtrl.clear();
    _savePhrases([..._phrases, text]);
  }

  void _removePhrase(String phrase) {
    _savePhrases(_phrases.where((p) => p != phrase).toList());
  }

  @override
  void dispose() {
    _glowController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _phraseCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleLogout(BuildContext context) async {
    final sos = context.read<SosController>();
    final auth = context.read<AuthProvider>();
    await sos.setVoiceEnabled(false);
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
        SnackBar(content: Text('Failed to save contact')),
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
      await contacts.remove(id);
    }
  }

  Future<void> _saveFile(String path, String label) async {
    final file = File(path);
    if (!await file.exists()) return;
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
                            message: sos.error,
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
                        _buildCameraSelector(sos),
                        if (sos.isTracking) _buildTrackingBanner(sos),
                        const SizedBox(height: 8),
                        _buildSosButton(sos),
                        if (sos.locationLink.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          _buildLocationCard(sos),
                        ],
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
          if (sos.status == SosStatus.cancelWindow)
            _buildCancelWindow(sos)
          else if (sos.status == SosStatus.countdown)
            _buildCountdown(sos)
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

  Widget _buildCancelWindow(SosController sos) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          Text(
            '${sos.cancelTimer ?? 0}',
            style: const TextStyle(
              fontSize: 64,
              fontWeight: FontWeight.bold,
              color: AppColors.orange500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'SOS will be sent in ${sos.cancelTimer ?? 0} seconds',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, color: Colors.white),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: sos.cancelSOS,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.gray700,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: const BorderSide(color: AppColors.red500, width: 2),
                ),
              ),
              child: const Text(
                '✕ CANCEL SOS',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCountdown(SosController sos) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Text(
            '${sos.countdown ?? 0}',
            style: const TextStyle(
              fontSize: 72,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const Text(
            'Get Ready!',
            style: TextStyle(fontSize: 20, color: Colors.white),
          ),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.green900.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.green500,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              sos.voiceEnabled
                  ? 'Voice Protection Active - Listening for "Help Me"'
                  : '24/7 Voice Protection Off',
              style: const TextStyle(color: AppColors.green400, fontSize: 13),
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
                child: _howItWorksStep('2', AppColors.orange600, 'Say "Help Me"'),
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
            'Voice Guard Phrases',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Colors.white),
          ),
          const SizedBox(height: 4),
          const Text(
            'Phrases that trigger an emergency SOS when spoken aloud.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          if (_phrasesLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (_phrases.isEmpty)
            const Text(
              'No phrases yet. Add one below.',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _phrases
                  .map(
                    (p) => InputChip(
                      label: Text(p),
                      labelStyle: const TextStyle(color: Colors.white, fontSize: 13),
                      backgroundColor: AppColors.gray700,
                      deleteIconColor: AppColors.red600,
                      onDeleted: () => _removePhrase(p),
                    ),
                  )
                  .toList(),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _phraseCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'e.g. Help Me',
                    hintStyle: const TextStyle(color: Colors.grey),
                    filled: true,
                    fillColor: AppColors.gray700,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (_) => _addPhrase(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _addPhrase,
                icon: const Icon(Icons.add, color: Colors.white),
                tooltip: 'Add phrase',
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.red600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
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
      if (mounted) setState(() {});
      _controller!.setLooping(true);
    });
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
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _player.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _playing = state == PlayerState.playing);
    });
    _player.setSourceDeviceFile(widget.path).then((_) {
      if (mounted) _player.resume();
    });
  }

  @override
  void dispose() {
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
