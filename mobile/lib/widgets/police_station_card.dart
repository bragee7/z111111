import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme.dart';
import '../models/police_station.dart';

/// Full station detail card: name, district, address, phone, coordinates,
/// distance, plus Call / Directions / Route here / WhatsApp actions.
///
/// Every action works with **no network**: Call and WhatsApp hand off to the
/// installed apps, Directions and Route here are computed by the on-device
/// router from the road graph bundled in the APK.
class PoliceStationCard extends StatelessWidget {
  const PoliceStationCard({
    super.key,
    required this.station,
    this.onRoute,
    this.onDirections,
    this.onShowOnMap,
    this.onWhatsApp,
    this.routeLabel,
    this.compact = false,
  });

  final PoliceStation station;
  final VoidCallback? onRoute;
  final VoidCallback? onDirections;
  final VoidCallback? onShowOnMap;
  final VoidCallback? onWhatsApp;

  /// e.g. "Route here" / "Route to me".
  final String? routeLabel;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final s = station;
    final dist = s.distanceLabel;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.gray200),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.policeLight.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Icon(Icons.local_police,
                    color: AppColors.policeBlue, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.name,
                      style: const TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.gray900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [s.city, s.district]
                          .where((e) => e != null && e.isNotEmpty)
                          .join(' • '),
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.gray500,
                      ),
                    ),
                  ],
                ),
              ),
              if (dist.isNotEmpty)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.blue50,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: AppColors.blue200),
                  ),
                  child: Text(
                    dist,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.policeBlue,
                    ),
                  ),
                ),
            ],
          ),
          if (!compact) ...[
            const SizedBox(height: 12),
            _row(Icons.place_outlined, 'Address', s.address ?? '—'),
            _row(Icons.phone_outlined, 'Phone',
                s.hasPhone ? s.phone! : 'No public number listed'),
            if (s.hasCoords)
              _row(
                Icons.my_location_outlined,
                'Coordinates',
                '${s.lat!.toStringAsFixed(6)}, ${s.lng!.toStringAsFixed(6)}',
              ),
            if (s.id.isNotEmpty) _row(Icons.badge_outlined, 'Station ID', s.id),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _action(
                  icon: Icons.call,
                  label: 'Call',
                  color: AppColors.safeGreen,
                  onTap: s.hasPhone
                      ? () => _launch('tel:${_digits(s.phone!)}')
                      : null,
                ),
                _action(
                  icon: Icons.navigation_outlined,
                  label: 'Directions',
                  color: AppColors.policeBlue,
                  onTap: onDirections ?? onRoute,
                ),
                if (onRoute != null)
                  _action(
                    icon: Icons.alt_route,
                    label: routeLabel ?? 'Route here',
                    color: AppColors.orange600,
                    onTap: onRoute,
                  ),
                _action(
                  icon: Icons.chat_bubble_outline,
                  label: 'WhatsApp',
                  color: AppColors.green700,
                  onTap: onWhatsApp ?? () => shareOnWhatsApp(s),
                ),
                if (onShowOnMap != null)
                  _action(
                    icon: Icons.map_outlined,
                    label: 'Show on map',
                    color: AppColors.gray600,
                    onTap: onShowOnMap,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Normalise a phone number for a tel: intent (keeps a leading +).
  static String _digits(String phone) {
    final plus = phone.trim().startsWith('+');
    final d = phone.replaceAll(RegExp(r'[^0-9]'), '');
    return plus ? '+$d' : d;
  }

  /// Share this station through WhatsApp.
  ///
  /// Tries the native `whatsapp://` scheme first (no network needed to open
  /// the app and pick a contact) and falls back to the wa.me web link.
  static Future<void> shareOnWhatsApp(PoliceStation s) async {
    final text = 'I need police help.\n'
        '${s.name}${s.city != null ? ', ${s.city}' : ''}'
        '${s.district.isNotEmpty ? ' (${s.district})' : ''}\n'
        '${s.hasPhone ? 'Phone: ${s.phone}\n' : ''}'
        '${s.address != null ? '${s.address}\n' : ''}'
        '${s.coordinatesText}\n'
        '${s.osmLink}';
    final encoded = Uri.encodeComponent(text);
    final native = Uri.parse('whatsapp://send?text=$encoded');
    try {
      if (await canLaunchUrl(native)) {
        await launchUrl(native, mode: LaunchMode.externalApplication);
        return;
      }
    } catch (_) {}
    try {
      await launchUrl(
        Uri.parse('https://wa.me/?text=$encoded'),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
  }

  Widget _row(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: AppColors.gray400),
          const SizedBox(width: 8),
          SizedBox(
            width: 78,
            child: Text(
              label,
              style: const TextStyle(fontSize: 11.5, color: AppColors.gray500),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 12.5,
                color: AppColors.gray800,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _action({
    required IconData icon,
    required String label,
    required Color color,
    VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        decoration: BoxDecoration(
          color: enabled
              ? color.withValues(alpha: 0.10)
              : AppColors.gray100,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: enabled ? color.withValues(alpha: 0.35) : AppColors.gray200,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: enabled ? color : AppColors.gray400),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: enabled ? color : AppColors.gray400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Future<void> _launch(String url) async {
    try {
      final uri = Uri.parse(url);
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        await Clipboard.setData(ClipboardData(text: url));
      }
    } catch (_) {
      try {
        await Clipboard.setData(ClipboardData(text: url));
      } catch (_) {}
    }
  }
}
