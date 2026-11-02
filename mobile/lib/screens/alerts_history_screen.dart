import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/theme.dart';
import '../core/widgets.dart';
import '../models/sos_case.dart';
import '../services/sos_service.dart';
import 'case_details_screen.dart';

class AlertsHistoryScreen extends StatefulWidget {
  const AlertsHistoryScreen({super.key});

  @override
  State<AlertsHistoryScreen> createState() => _AlertsHistoryScreenState();
}

class _AlertsHistoryScreenState extends State<AlertsHistoryScreen> {
  final SosService _sosService = SosService();

  List<SosCase> _cases = [];
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _fetchCases();
  }

  Future<void> _fetchCases() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final cases = await _sosService.getCases();
      if (!mounted) return;
      setState(() {
        _cases = cases;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _cases = [];
        _loading = false;
        _error = 'Could not load alerts. Check your connection and retry.';
      });
    }
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '';
    return DateFormat('MMM d, yyyy h:mm a').format(date.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.gray900,
      appBar: AppBar(
        backgroundColor: AppColors.gray900,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('My Alerts'),
      ),
      body: _loading
          ? const Center(child: LoadingSpinner(color: AppColors.blue400, size: 44))
          : _cases.isEmpty
              ? Center(
                  child: _error.isNotEmpty
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _error,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: AppColors.gray400, fontSize: 14),
                            ),
                            const SizedBox(height: 12),
                            ElevatedButton.icon(
                              onPressed: _fetchCases,
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.blue600),
                              icon: const Icon(Icons.refresh, size: 18),
                              label: const Text('Retry'),
                            ),
                          ],
                        )
                      : const Text(
                          'No SOS alerts yet.\nTap SEND SOS ALERT to raise one.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: AppColors.gray500, fontSize: 14),
                        ),
                )
              : RefreshIndicator(
                  onRefresh: _fetchCases,
                  color: AppColors.blue400,
                  backgroundColor: AppColors.gray800,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    itemCount: _cases.length,
                    itemBuilder: (context, index) => _buildTile(_cases[index]),
                  ),
                ),
    );
  }

  Widget _buildTile(SosCase c) {
    final pending = c.isPending;
    final (bg, fg) = pending
        ? (AppColors.red600, Colors.white)
        : (AppColors.green700, Colors.white);
    final trigger = c.triggerType == null || c.triggerType!.isEmpty
        ? 'Manual'
        : '${c.triggerType![0].toUpperCase()}${c.triggerType!.substring(1)}';

    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => CaseDetailsScreen(caseId: c.id)),
        );
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: AppColors.gray800,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: pending ? AppColors.red600 : AppColors.green700,
              ),
              alignment: Alignment.center,
              child: Icon(
                pending ? Icons.warning_amber_rounded : Icons.check,
                color: Colors.white,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'SOS Alert #${c.id}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _formatDate(c.createdAt ?? c.timestamp),
                    style: const TextStyle(color: AppColors.gray400, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                StatusPill(label: c.status, background: bg, foreground: fg),
                const SizedBox(height: 4),
                Text(
                  trigger,
                  style: const TextStyle(color: AppColors.gray500, fontSize: 11),
                ),
              ],
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, color: AppColors.gray600, size: 20),
          ],
        ),
      ),
    );
  }
}