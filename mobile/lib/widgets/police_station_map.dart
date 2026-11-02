import 'dart:math' as dart_math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../core/theme.dart';
import '../models/police_station.dart';
import '../services/offline_data_service.dart';
import 'offline_map_view.dart';

/// The police-station map.
///
/// **100% offline.** There is no Google Maps SDK and no tile server anywhere in
/// this widget: every road, town label and marker is painted from the road graph
/// and station list bundled in the APK, so it works in airplane mode and never
/// waits on a network request.
class PoliceStationMap extends StatefulWidget {
  const PoliceStationMap({
    super.key,
    this.stations = const [],
    this.highlight,
    this.userPoint,
    this.userAccuracy,
    this.route,
    this.followUser = false,
    this.pickMode = false,
    this.onPick,
    this.onStationTap,
    this.showControls = true,
    this.controller,
    this.dark = true,
  });

  final List<PoliceStation> stations;
  final PoliceStation? highlight;
  final LatLng? userPoint;
  final double? userAccuracy;
  final PoliceRoute? route;
  final bool followUser;
  final bool pickMode;
  final void Function(LatLng)? onPick;
  final void Function(PoliceStation)? onStationTap;
  final bool showControls;
  final OfflineMapController? controller;
  final bool dark;

  @override
  State<PoliceStationMap> createState() => PoliceStationMapState();
}

class PoliceStationMapState extends State<PoliceStationMap> {
  late OfflineMapController _cam;

  static const LatLng _tnCenter = LatLng(11.0, 78.6);

  @override
  void initState() {
    super.initState();
    _cam = widget.controller ??
        OfflineMapController(
          center: widget.userPoint ?? _tnCenter,
          zoom: widget.userPoint != null ? 14 : 7.2,
        );
  }

  @override
  void didUpdateWidget(covariant PoliceStationMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != null && widget.controller != oldWidget.controller) {
      _cam = widget.controller!;
    }
  }

  void recenter() {
    final p = widget.userPoint;
    if (p != null) {
      _cam.move(p, _cam.zoom < 13 ? 14 : _cam.zoom);
    }
  }

  void fitRoute() {
    final r = widget.route;
    if (r == null || r.geometry.length < 2) return;
    var s = r.geometry.first.latitude, n = r.geometry.first.latitude;
    var w = r.geometry.first.longitude, e = r.geometry.first.longitude;
    for (final p in r.geometry) {
      if (p.latitude < s) s = p.latitude;
      if (p.latitude > n) n = p.latitude;
      if (p.longitude < w) w = p.longitude;
      if (p.longitude > e) e = p.longitude;
    }
    final span = (n - s) > (e - w) ? (n - s) : (e - w);
    // 0.002 deg ~ 220 m -> zoom 14.2, and every doubling halves about 1 zoom.
    final z = span <= 0.0005
        ? 15.5
        : (14.2 - (dart_math.log(span / 0.002) / dart_math.ln2)).clamp(9.5, 16.0);
    _cam.move(LatLng((s + n) / 2, (w + e) / 2), z);
  }

  @override
  Widget build(BuildContext context) {
    final offline = OfflineDataService.instance;
    final graph = offline.graph;

    return Stack(
      children: [
        OfflineMapView(
          controller: _cam,
          graph: graph,
          stations: widget.stations.where((s) => s.hasCoords).toList(),
          places: offline.places,
          userPoint: widget.userPoint,
          userAccuracyMetres: widget.userAccuracy,
          route: widget.route,
          focusStation: widget.highlight,
          followUser: widget.followUser,
          dark: widget.dark,
          onStationTap: widget.onStationTap,
          onMapTap: widget.pickMode && widget.onPick != null
              ? (p) => widget.onPick!(p)
              : null,
        ),
        if (widget.showControls)
          Positioned(
            right: 12,
            bottom: 22,
            child: Column(
              children: [
                _MapButton(
                  icon: Icons.my_location,
                  dark: widget.dark,
                  onTap: recenter,
                ),
                if (widget.route != null &&
                    widget.route!.geometry.length > 1) ...[
                  const SizedBox(height: 8),
                  _MapButton(
                    icon: Icons.alt_route,
                    dark: widget.dark,
                    onTap: () {
                      final r = widget.route!;
                      final mid = r.geometry[r.geometry.length ~/ 2];
                      _cam.move(mid, 13);
                    },
                  ),
                ],
              ],
            ),
          ),
        // zoom buttons: cheap, always visible, no scroll-wheel needed on a phone
        if (widget.showControls)
          Positioned(
            left: 12,
            bottom: 22,
            child: Column(
              children: [
                _MapButton(
                  icon: Icons.add,
                  dark: widget.dark,
                  onTap: () => _cam.move(_cam.center, (_cam.zoom + 1).clamp(5, 18)),
                ),
                const SizedBox(height: 8),
                _MapButton(
                  icon: Icons.remove,
                  dark: widget.dark,
                  onTap: () => _cam.move(_cam.center, (_cam.zoom - 1).clamp(5, 18)),
                ),
              ],
            ),
          ),
        if (widget.pickMode)
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.amber300,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                children: [
                  Icon(Icons.touch_app, color: Colors.black87, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Tap anywhere on the map to set your location',
                      style: TextStyle(
                        color: Colors.black87,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (graph == null)
          const Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: _OfflineNotice(
              text: 'Loading the bundled offline map\u2026',
            ),
          ),
      ],
    );
  }
}

class _OfflineNotice extends StatelessWidget {
  const _OfflineNotice({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.66),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.8),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white, fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _MapButton extends StatelessWidget {
  const _MapButton({
    required this.icon,
    required this.onTap,
    this.dark = true,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: dark ? const Color(0xFF1A2436) : Colors.white,
      borderRadius: BorderRadius.circular(10),
      elevation: 3,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: SizedBox(
          width: 38,
          height: 38,
          child: Icon(
            icon,
            size: 20,
            color: dark ? Colors.white : Colors.black87,
          ),
        ),
      ),
    );
  }
}
