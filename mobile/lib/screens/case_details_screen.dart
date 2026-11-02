import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../core/config.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../models/sos_case.dart';
import '../services/sos_service.dart';
import '../state/auth_provider.dart';

class CaseDetailsScreen extends StatefulWidget {
  final String caseId;
  const CaseDetailsScreen({super.key, required this.caseId});

  @override
  State<CaseDetailsScreen> createState() => _CaseDetailsScreenState();
}

class _CaseDetailsScreenState extends State<CaseDetailsScreen> {
  final SosService _sosService = SosService();
  final _dateFormat = DateFormat('EEEE, MMMM d, yyyy h:mm:ss a');

  SosCase? _caseData;
  bool _loading = true;
  String _error = '';
  String _notes = '';
  final TextEditingController _notesController = TextEditingController();
  bool _saving = false;
  bool _updating = false;

  VideoPlayerController? _videoController;
  final AudioPlayer _audioPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    _fetchCase();
  }

  Future<void> _fetchCase() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final caseData = await _sosService.getCase(widget.caseId);
      if (!mounted) return;
      setState(() {
        _caseData = caseData;
        _notes = caseData.notes;
        _notesController.text = caseData.notes;
        _loading = false;
      });
      _initMedia(caseData);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load case details';
        _loading = false;
      });
    }
  }

  Future<void> _initMedia(SosCase caseData) async {
    _videoController?.dispose();
    _videoController = null;
    final videoUrl = AppConfig.mediaUrl(caseData.videoUrl);
    if (videoUrl.isNotEmpty) {
      try {
        _videoController = VideoPlayerController.networkUrl(Uri.parse(videoUrl));
        await _videoController!.initialize();
        if (mounted) setState(() {});
      } catch (_) {}
    }
    final audioUrl = AppConfig.mediaUrl(caseData.audioUrl);
    if (audioUrl.isNotEmpty) {
      try {
        await _audioPlayer.setSourceUrl(audioUrl);
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _videoController?.dispose();
    _audioPlayer.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _handleStatusUpdate(String newStatus) async {
    setState(() => _updating = true);
    try {
      await _sosService.updateCase(widget.caseId, status: newStatus, notes: _notes);
      await _fetchCase();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Failed to update case');
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _handleNotesUpdate() async {
    setState(() => _saving = true);
    try {
      await _sosService.updateCase(widget.caseId, notes: _notes);
      await _fetchCase();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Failed to update notes');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openMaps(String link) async {
    final uri = Uri.parse(link);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _exportPdf() async {
    final caseData = _caseData;
    if (caseData == null) return;

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(48),
        build: (context) => [
          pw.Container(
            decoration: const pw.BoxDecoration(
              border: pw.Border(bottom: pw.BorderSide(color: PdfColors.red600, width: 3)),
            ),
            padding: const pw.EdgeInsets.only(bottom: 16),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('Emergency Case Report',
                    style: pw.TextStyle(color: PdfColors.red700, fontSize: 28, fontWeight: pw.FontWeight.bold)),
                pw.SizedBox(height: 4),
                pw.Text('Women Safety Guardian - Incident Documentation',
                    style: pw.TextStyle(color: PdfColors.grey600, fontSize: 14)),
              ],
            ),
          ),
          pw.SizedBox(height: 32),
          _sectionTitle('Case Information'),
          _table([
            _row('Case ID', caseData.id),
            _row('Status', caseData.status),
            _row('Reporter', caseData.userEmail ?? 'Unknown'),
            _row('Reported At', _formatFull(caseData.timestamp)),
            _row('Last Updated',
                caseData.updatedAt != null ? _formatFull(caseData.updatedAt) : _formatFull(caseData.timestamp)),
            _row('Trigger Type', caseData.triggerType ?? 'Manual'),
          ]),
          _sectionTitle('Location Details'),
          _table([
            _row('Coordinates',
                caseData.latitude != null ? '${caseData.latitude}, ${caseData.longitude}' : 'Not captured'),
            _row('Google Maps', caseData.locationLink ?? 'Not available'),
          ]),
          _sectionTitle('Media Evidence'),
          _table([
            _row('Video Recording', caseData.videoUrl != null ? 'Captured' : 'Not available'),
            _row('Audio Recording', caseData.audioUrl != null ? 'Captured' : 'Not available'),
          ]),
          _sectionTitle('Notes'),
          pw.Text(caseData.notes.isEmpty ? 'No notes recorded' : caseData.notes,
              style: const pw.TextStyle(color: PdfColors.grey900, fontSize: 13, lineSpacing: 4)),
          pw.SizedBox(height: 48),
          pw.Divider(color: PdfColors.grey300),
          pw.SizedBox(height: 12),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              pw.Text('Generated by Women Safety Guardian',
                  style: pw.TextStyle(color: PdfColors.grey500, fontSize: 11)),
              pw.SizedBox(height: 4),
              pw.Text(DateFormat('MMM d, yyyy h:mm:ss a').format(DateTime.now()),
                  style: pw.TextStyle(color: PdfColors.grey500, fontSize: 11)),
              pw.SizedBox(height: 4),
              pw.Text('This is a computer-generated report.',
                  style: pw.TextStyle(color: PdfColors.grey500, fontSize: 11)),
            ],
          ),
        ],
      ),
    );

    try {
      await Printing.layoutPdf(onLayout: (format) => doc.save());
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Failed to export PDF: $e');
    }
  }

  pw.Widget _sectionTitle(String title) {
    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 12),
      padding: const pw.EdgeInsets.only(bottom: 6),
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: PdfColors.grey300, width: 1)),
      ),
      child: pw.Text(title,
          style: pw.TextStyle(color: PdfColors.grey800, fontSize: 18, fontWeight: pw.FontWeight.bold)),
    );
  }

  pw.Widget _table(List<pw.Widget> rows) {
    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 24),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: rows,
      ),
    );
  }

  pw.Widget _row(String label, String value) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 6),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(
              width: 160,
              child: pw.Text(label, style: pw.TextStyle(color: PdfColors.grey600, fontWeight: pw.FontWeight.bold)),
            ),
            pw.Expanded(child: pw.Text(value, style: const pw.TextStyle(color: PdfColors.grey900))),
          ],
        ),
      );

  String _formatFull(DateTime? date) {
    if (date == null) return '';
    return _dateFormat.format(date.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    final isPolice = context.watch<AuthProvider>().user?.isPolice ?? false;

    return Scaffold(
      backgroundColor: AppColors.gray900,
      appBar: AppBar(
        backgroundColor: AppColors.gray900,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Case Details'),
      ),
      body: _loading
          ? const LoadingSpinner(color: AppColors.policeLight, size: 56)
          : _caseData == null
              ? _buildNotFound()
              : _buildContent(isPolice),
    );
  }

  Widget _buildNotFound() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Case not found', style: TextStyle(fontSize: 20, color: Colors.white)),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.policeBlue),
            child: const Text('Go Back'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(bool isPolice) {
    final caseData = _caseData!;
    final pending = caseData.isPending;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error.isNotEmpty) ...[
                AppBanner(message: _error, isError: true, onDismiss: () => setState(() => _error = '')),
              ],
              _buildHeader(caseData, pending),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _buildVideoSection(caseData)),
                  const SizedBox(width: 12),
                  Expanded(child: _buildAudioSection(caseData)),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _buildLocationSection(caseData)),
                  const SizedBox(width: 12),
                  Expanded(child: _buildInfoSection(caseData)),
                ],
              ),
              const SizedBox(height: 16),
              _buildNotesSection(caseData),
              if (isPolice) ...[
                const SizedBox(height: 16),
                _buildActionsSection(caseData),
              ],
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(SosCase caseData, bool pending) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.gray800,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Emergency Case Details',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Case ID: ',
                      style: TextStyle(color: AppColors.gray400),
                    ),
                  ],
                ),
              ),
              StatusPill(
                label: caseData.status,
                background: pending ? AppColors.red900 : AppColors.green900,
                foreground: pending ? AppColors.red200 : AppColors.green200,
                pulsing: pending,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildVideoSection(SosCase caseData) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.gray800,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Video Recording',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
          ),
          const SizedBox(height: 12),
          if (caseData.videoUrl != null)
            _buildVideoPlayer()
          else
            _noMedia(Icons.videocam_off_outlined, 'No video available'),
        ],
      ),
    );
  }

  Widget _buildVideoPlayer() {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) {
      return Container(
        height: 140,
        decoration: BoxDecoration(
          color: AppColors.gray900,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: const LoadingSpinner(color: AppColors.policeLight, size: 24),
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
                  size: 48,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAudioSection(SosCase caseData) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.gray800,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Audio Recording',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
          ),
          const SizedBox(height: 12),
          if (caseData.audioUrl != null)
            _AudioPlayerTile(player: _audioPlayer)
          else
            _noMedia(Icons.mic_off_outlined, 'No audio available'),
        ],
      ),
    );
  }

  Widget _noMedia(IconData icon, String text) {
    return Container(
      height: 140,
      decoration: BoxDecoration(
        color: AppColors.gray900,
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: AppColors.gray600, size: 40),
          const SizedBox(height: 8),
          Text(text, style: const TextStyle(color: AppColors.gray500, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildLocationSection(SosCase caseData) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.gray800,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Location',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
          ),
          const SizedBox(height: 12),
          if (caseData.locationLink != null) ...[
            ElevatedButton.icon(
              onPressed: () => _openMaps(caseData.locationLink!),
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.blue600),
              icon: const Icon(Icons.location_on_outlined, size: 18),
              label: const Text('Open in Google Maps'),
            ),
            const SizedBox(height: 8),
            Text(
              caseData.locationLink!,
              style: const TextStyle(color: AppColors.gray400, fontSize: 13),
            ),
          ] else
            const Text(
              'No location data available',
              style: TextStyle(color: AppColors.gray500),
            ),
        ],
      ),
    );
  }

  Widget _buildInfoSection(SosCase caseData) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.gray800,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Case Information',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
          ),
          const SizedBox(height: 12),
          _infoRow('Reporter:', caseData.userEmail ?? 'Unknown'),
          const SizedBox(height: 8),
          _infoRow('Timestamp:', _formatFull(caseData.timestamp)),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(
                width: 110,
                child: Text('Status:', style: TextStyle(color: AppColors.gray400)),
              ),
              Expanded(
                child: Text(
                  caseData.status,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: caseData.isPending ? AppColors.red400 : AppColors.green400,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(label, style: const TextStyle(color: AppColors.gray400)),
        ),
        Expanded(
          child: Text(value, style: const TextStyle(color: Colors.white, fontSize: 13)),
        ),
      ],
    );
  }

  Widget _buildNotesSection(SosCase caseData) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.gray800,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Notes',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _notesController,
            onChanged: (v) => _notes = v,
            maxLines: 5,
            style: const TextStyle(color: AppColors.gray900),
            decoration: const InputDecoration(
              hintText: 'Add notes about this case...',
              filled: true,
              fillColor: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: (_saving || _notes == caseData.notes) ? null : _handleNotesUpdate,
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.blue600),
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                  )
                : const Text('Save Notes'),
          ),
        ],
      ),
    );
  }

  Widget _buildActionsSection(SosCase caseData) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.gray800,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Case Actions',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (caseData.isPending) ...[
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _updating ? null : () => _handleStatusUpdate('Resolved'),
                    style: ElevatedButton.styleFrom(backgroundColor: AppColors.green600),
                    icon: const Icon(Icons.check_circle_outline, size: 18),
                    label: const Text('Mark as Resolved'),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              if (!caseData.isPending) ...[
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _updating ? null : () => _handleStatusUpdate('Pending'),
                    style: ElevatedButton.styleFrom(backgroundColor: AppColors.orange600),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Reopen Case'),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _exportPdf,
                  style: ElevatedButton.styleFrom(backgroundColor: AppColors.gray600),
                  icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                  label: const Text('Export PDF Report'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AudioPlayerTile extends StatefulWidget {
  final AudioPlayer player;
  const _AudioPlayerTile({required this.player});

  @override
  State<_AudioPlayerTile> createState() => _AudioPlayerTileState();
}

class _AudioPlayerTileState extends State<_AudioPlayerTile> {
  bool _playing = false;
  StreamSubscription<PlayerState>? _stateSub;

  @override
  void initState() {
    super.initState();
    _stateSub = widget.player.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _playing = state == PlayerState.playing);
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 140,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.gray900,
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: () async {
              if (_playing) {
                await widget.player.pause();
              } else {
                await widget.player.resume();
              }
            },
            icon: Icon(
              _playing ? Icons.pause_circle : Icons.play_circle,
              color: AppColors.blue300,
              size: 48,
            ),
          ),
          const Text(
            'Audio Recording',
            style: TextStyle(color: AppColors.gray300, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
