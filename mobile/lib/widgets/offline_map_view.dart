import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../models/place_label.dart';
import '../models/police_station.dart';
import '../services/road_graph.dart';

/// Controls the camera of an [OfflineMapView] from outside.
class OfflineMapController extends ChangeNotifier {
  OfflineMapController({
    required LatLng center,
    this.zoom = 12,
  }) : _center = center;

  LatLng _center;
  double zoom;
  bool _attached = false;

  LatLng get center => _center;

  void move(LatLng c, [double? z]) {
    _center = c;
    if (z != null) zoom = z;
    if (_attached) notifyListeners();
  }

  void zoomBy(double delta) {
    zoom = (zoom + delta).clamp(5.0, 18.0);
    if (_attached) notifyListeners();
  }
}

/// A fully offline, canvas-drawn map of Tamil Nadu built from the road graph
/// bundled in the APK.
///
/// There is no tile server, no Google Maps and no network call of any kind:
/// every pixel comes from `assets/tn_roads.bin.gz` plus the station list.
///
/// Performance: the widget is split into two painters.
///  * the **road layer** repaints only when the camera moves, and
///  * the **overlay layer** (route, markers, user dot) repaints on the pulse
///    animation.
/// So the animation never re-draws thousands of road segments.
class OfflineMapView extends StatefulWidget {
  const OfflineMapView({
    super.key,
    this.controller,
    required this.graph,
    this.stations = const [],
    this.places = const [],
    this.userPoint,
    this.userAccuracyMetres,
    this.userHeading,
    this.route,
    this.focusStation,
    this.followUser = false,
    this.onStationTap,
    this.onMapTap,
    this.onUserPan,
    this.showAttribution = true,
    this.dark = true,
  });

  final OfflineMapController? controller;
  final RoadGraph? graph;
  final List<PoliceStation> stations;
  final List<PlaceLabel> places;
  final LatLng? userPoint;
  final double? userAccuracyMetres;
  final double? userHeading;
  final PoliceRoute? route;
  final PoliceStation? focusStation;
  final bool followUser;
  final void Function(PoliceStation station)? onStationTap;
  final void Function(LatLng point)? onMapTap;
  final VoidCallback? onUserPan;
  final bool showAttribution;
  final bool dark;

  @override
  State<OfflineMapView> createState() => OfflineMapViewState();
}

class OfflineMapViewState extends State<OfflineMapView>
    with SingleTickerProviderStateMixin {
  static const double _minZoom = 5.0;
  static const double _maxZoom = 18.0;

  late double _zoom;
  late LatLng _center;

  /// Fires when the camera moves: repaints the road layer.
  final ValueNotifier<int> _camRepaint = ValueNotifier<int>(0);

  /// Fires on the pulse animation: repaints the overlay only.
  final ValueNotifier<int> _animRepaint = ValueNotifier<int>(0);

  late final _Projection _proj = _Projection();
  late final _RoadPainter _roadPainter = _RoadPainter(_camRepaint, _proj);
  late final _OverlayPainter _overlayPainter =
      _OverlayPainter(_camRepaint, _animRepaint, _proj);

  late final AnimationController _glow =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat();

  void _onGlowTick() {
    if (mounted) _animRepaint.value++;
  }

  Size _size = Size.zero;
  bool _lastFollow = false;
  bool _userCentred = false;

  LatLng get center => _center;
  double get zoom => _zoom;

  @override
  void initState() {
    super.initState();
    final c = widget.controller;
    _center = c?.center ?? const LatLng(11.0, 78.6);
    _zoom = (c?.zoom ?? 12).clamp(_minZoom, _maxZoom);
    _lastFollow = widget.followUser;
    c?._attached = true;
    c?.addListener(_onExternalCamera);
    _glow.addListener(_onGlowTick);
  }

  @override
  void didUpdateWidget(covariant OfflineMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller?._attached = false;
      oldWidget.controller?.removeListener(_onExternalCamera);
      widget.controller?._attached = true;
      widget.controller?.addListener(_onExternalCamera);
    }

    // The first time we learn where the user is, put the map on them.
    if (widget.userPoint != null &&
        oldWidget.userPoint == null &&
        !_userCentred) {
      _userCentred = true;
      _center = widget.userPoint!;
      if (_zoom < 13) _zoom = 14;
      widget.controller?.move(_center, _zoom);
    }

    // Follow the user while they move.
    if (widget.followUser && widget.userPoint != null) {
      final p = widget.userPoint!;
      if (_lastFollow && oldWidget.userPoint != widget.userPoint) {
        _center = p;
        if (_zoom < 13) _zoom = 14;
        widget.controller?.move(_center, _zoom);
        _bump();
      }
    }
    if (widget.followUser && !_lastFollow) {
      final p = widget.userPoint;
      if (p != null) {
        _center = p;
        if (_zoom < 13) _zoom = 14;
        widget.controller?.move(_center, _zoom);
        _bump();
      }
    }
    _lastFollow = widget.followUser;

    // A route arriving should frame itself.
    if (widget.route != null && widget.route != oldWidget.route) {
      _frameRoute(widget.route!);
    }
    if (widget.focusStation != null &&
        widget.focusStation != oldWidget.focusStation) {
      final s = widget.focusStation!;
      if (s.lat != null && s.lng != null) {
        _center = LatLng(s.lat!, s.lng!);
        _zoom = math.max(_zoom, 15);
        widget.controller?.move(_center, _zoom);
        _bump();
      }
    }
    _bump();
  }

  @override
  void dispose() {
    widget.controller?._attached = false;
    widget.controller?.removeListener(_onExternalCamera);
    _glow.removeListener(_onGlowTick);
    _glow.dispose();
    _camRepaint.dispose();
    _animRepaint.dispose();
    super.dispose();
  }

  void _onExternalCamera() {
    final c = widget.controller;
    if (c == null) return;
    _center = c.center;
    _zoom = c.zoom.clamp(_minZoom, _maxZoom);
    _bump();
  }

  void _bump() {
    if (!mounted) return;
    // The painters can repaint without a widget rebuild (the camera changed),
    // so the shared projection has to be refreshed here, not only in build().
    _proj
      ..center = _center
      ..zoom = _zoom
      ..size = _size;
    _camRepaint.value++;
  }

  void _frameRoute(PoliceRoute r) {
    final pts = <LatLng>[
      ...r.geometry,
      if (widget.userPoint != null) widget.userPoint!,
    ];
    if (pts.length < 2) return;
    var s = pts.first.latitude, n = pts.first.latitude;
    var w = pts.first.longitude, e = pts.first.longitude;
    for (final p in pts) {
      if (p.latitude < s) s = p.latitude;
      if (p.latitude > n) n = p.latitude;
      if (p.longitude < w) w = p.longitude;
      if (p.longitude > e) e = p.longitude;
    }
    final span = math.max(n - s, (e - w) * 0.85);
    var z = 15.0;
    if (span > 0.002) z = 13.2 - math.log(span / 0.002) / math.ln2;
    _zoom = z.clamp(10.0, 16.5);
    _center = LatLng((s + n) / 2, (w + e) / 2);
    widget.controller?.move(_center, _zoom);
    _bump();
  }

  // ------------------------------------------------------------ gestures

  double _pinchStartZoom = 12;
  Offset _pinchFocal = Offset.zero;
  LatLng? _gestureStartCenter;

  void _onScaleStart(ScaleStartDetails d) {
    _pinchStartZoom = _zoom;
    _pinchFocal = d.localFocalPoint;
    _gestureStartCenter = _center;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_size == Size.zero) return;
    final zoomed = d.scale != 1.0;
    if (zoomed) {
      _zoom = (_pinchStartZoom + math.log(d.scale) / math.ln2)
          .clamp(_minZoom, _maxZoom);
    }
    if (d.pointerCount == 1) {
      // one finger: pan
      final world = 256.0 * math.pow(2, _zoom).toDouble();
      final cur = _center;
      final nx = _nx(cur.longitude) - d.focalPointDelta.dx / world;
      final ny = _ny(cur.latitude) - d.focalPointDelta.dy / world;
      _center = LatLng(_latFromNy(ny), _lngFromNx(nx));
      widget.onUserPan?.call();
    } else if (zoomed && _gestureStartCenter != null) {
      // two fingers: zoom, keeping the focal point anchored
      final world = 256.0 * math.pow(2, _zoom).toDouble();
      final dx = (_pinchFocal.dx - _size.width / 2) / world;
      final dy = (_pinchFocal.dy - _size.height / 2) / world;
      final startWorld = 256.0 * math.pow(2, _pinchStartZoom).toDouble();
      final sdx = (_pinchFocal.dx - _size.width / 2) / startWorld;
      final sdy = (_pinchFocal.dy - _size.height / 2) / startWorld;
      final nx = _nx(_gestureStartCenter!.longitude) + sdx - dx;
      final ny = _ny(_gestureStartCenter!.latitude) + sdy - dy;
      _center = LatLng(_latFromNy(ny), _lngFromNx(nx));
      widget.onUserPan?.call();
    }
    widget.controller?.move(_center, _zoom);
    _bump();
  }

  void _onTapUp(TapUpDetails d) {
    // station hit test
    final world = 256.0 * math.pow(2, _zoom).toDouble();
    final cx = _nx(_center.longitude);
    final cy = _ny(_center.latitude);
    PoliceStation? best;
    var bestD = 32.0 * 32.0;
    for (final s in widget.stations) {
      if (s.lat == null || s.lng == null) continue;
      final dx = (_nx(s.lng!) - cx) * world + _size.width / 2 - d.localPosition.dx;
      final dy = (_ny(s.lat!) - cy) * world + _size.height / 2 - d.localPosition.dy;
      final dd = dx * dx + dy * dy;
      if (dd < bestD) {
        bestD = dd;
        best = s;
      }
    }
    if (best != null) {
      widget.onStationTap?.call(best);
      return;
    }
    final nx = cx + (d.localPosition.dx - _size.width / 2) / world;
    final ny = cy + (d.localPosition.dy - _size.height / 2) / world;
    widget.onMapTap?.call(LatLng(_latFromNy(ny), _lngFromNx(nx)));
  }

  void _zoomBy(double delta, [Offset? focal]) {
    final before = focal == null ? null : _screenToLatLng(focal);
    _zoom = (_zoom + delta).clamp(_minZoom, _maxZoom);
    if (before != null && focal != null) {
      final after = _screenToLatLng(focal);
      _center = LatLng(
        _center.latitude + (before.latitude - after.latitude),
        _center.longitude + (before.longitude - after.longitude),
      );
    }
    widget.controller?.move(_center, _zoom);
    _bump();
  }

  LatLng _screenToLatLng(Offset p) {
    final world = 256.0 * math.pow(2, _zoom).toDouble();
    final nx = _nx(_center.longitude) + (p.dx - _size.width / 2) / world;
    final ny = _ny(_center.latitude) + (p.dy - _size.height / 2) / world;
    return LatLng(_latFromNy(ny), _lngFromNx(nx));
  }

  /// Recentre on the active route / user.
  void recenter() {
    final r = widget.route;
    if (r != null && r.geometry.length > 1) {
      _frameRoute(r);
      return;
    }
    final p = widget.userPoint;
    if (p != null) {
      _center = p;
      if (_zoom < 13) _zoom = 14;
      widget.controller?.move(_center, _zoom);
      _bump();
    }
  }

  // ------------------------------------------------------------ projection

  static double _nx(double lng) => (lng + 180.0) / 360.0;

  static double _ny(double lat) {
    final clamped = lat.clamp(-85.0, 85.0);
    final s = math.sin(clamped * math.pi / 180.0);
    return 0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi);
  }

  static double _lngFromNx(double nx) => nx * 360.0 - 180.0;

  static double _latFromNy(double ny) {
    final n = math.pi * (1 - 2 * ny);
    return math.atan((math.exp(n) - math.exp(-n)) / 2) * 180.0 / math.pi;
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.dark ? const Color(0xFF0C1220) : const Color(0xFFF3F1EA);
    return LayoutBuilder(builder: (context, constraints) {
      _size = Size(constraints.maxWidth, constraints.maxHeight);
      _proj
        ..center = _center
        ..zoom = _zoom
        ..size = _size;
      _roadPainter
        ..graph = widget.graph
        ..dark = widget.dark;
      _overlayPainter
        ..stations = widget.stations
        ..places = widget.places
        ..userPoint = widget.userPoint
        ..userAccuracy = widget.userAccuracyMetres
        ..userHeading = widget.userHeading
        ..route = widget.route
        ..focus = widget.focusStation
        ..dark = widget.dark;

      return ClipRect(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onTapUp: _onTapUp,
          onDoubleTapDown: (d) => _zoomBy(1, d.localPosition),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: bg),
              RepaintBoundary(
                child: CustomPaint(
                  painter: _roadPainter,
                  isComplex: true,
                  willChange: true,
                ),
              ),
              RepaintBoundary(
                child: CustomPaint(
                  painter: _overlayPainter,
                  isComplex: true,
                ),
              ),
              if (widget.showAttribution)
                Positioned(
                  left: 6,
                  bottom: 4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 2),
                      child: Text(
                        '\u00a9 OpenStreetMap contributors',
                        style: TextStyle(
                          fontSize: 9,
                          color: Colors.white.withValues(alpha: 0.72),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }
}

// ---------------------------------------------------------------------------
// shared projection
// ---------------------------------------------------------------------------

class _Projection {
  LatLng center = const LatLng(11, 78.6);
  double zoom = 12;
  Size size = Size.zero;

  double _world = 0;
  double _cx = 0;
  double _cy = 0;

  static double _ny(double lat) {
    final clamped = lat.clamp(-85.0, 85.0);
    final s = math.sin(clamped * math.pi / 180.0);
    return 0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi);
  }

  static double _nx(double lng) => (lng + 180.0) / 360.0;

  void sync() {
    _world = 256.0 * math.pow(2, zoom).toDouble();
    _cx = _nx(center.longitude);
    _cy = _ny(center.latitude);
  }

  double get world => _world;

  Offset toScreen(double lat, double lng) => Offset(
        (_nx(lng) - _cx) * _world + size.width / 2,
        (_ny(lat) - _cy) * _world + size.height / 2,
      );

  /// Latitude/longitude of the screen edges.
  double latAt(double y) {
    final n = math.pi * (1 - 2 * (_cy + (y - size.height / 2) / _world));
    return math.atan((math.exp(n) - math.exp(-n)) / 2) * 180.0 / math.pi;
  }

  double lngAt(double x) =>
      (((_cx + (x - size.width / 2) / _world)) * 360.0) - 180.0;
}

// ---------------------------------------------------------------------------
// road layer
// ---------------------------------------------------------------------------

class _RoadPainter extends CustomPainter {
  _RoadPainter(Listenable repaint, this.proj) : super(repaint: repaint);

  final _Projection proj;

  RoadGraph? graph;
  bool dark = true;

  final Int32ListSink _visible = Int32ListSink();
  final Map<int, ui.Path> _paths = {};
  final Paint _casing = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final Paint _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  @override
  void paint(Canvas canvas, Size s) {
    final g = graph;
    if (g == null || g.isEmpty) return;
    proj.sync();

    final nLat = proj.latAt(0);
    final sLat = proj.latAt(s.height);
    final wLng = proj.lngAt(0);
    final eLng = proj.lngAt(s.width);

    _visible.clear();
    g.edgesInBox(sLat, wLng, nLat, eLng, _visible);

    final maxClass = _maxClassForZoom(proj.zoom);
    for (final p in _paths.values) {
      p.reset();
    }

    final vd = _visible.data;
    final vlen = _visible.length;
    for (var i = 0; i < vlen; i++) {
      final e = vd[i];
      final cls = g.edgeClass(e);
      if (cls > maxClass) continue;
      final path = _paths.putIfAbsent(cls, () => ui.Path());
      final a = g.edgeA(e);
      final b = g.edgeB(e);
      final pa = proj.toScreen(g.latAt(a), g.lngAt(a));
      final pb = proj.toScreen(g.latAt(b), g.lngAt(b));
      path.moveTo(pa.dx, pa.dy);
      path.lineTo(pb.dx, pb.dy);
    }

    // draw small -> large so the big roads sit on top
    for (var cls = maxClass; cls >= 0; cls--) {
      final path = _paths[cls];
      if (path == null) continue;
      final style = _styleFor(cls);
      if (cls <= RoadGraph.cTertiary) {
        _casing
          ..strokeWidth = style.width + 2.2
          ..color = dark ? const Color(0xFF05080F) : const Color(0xFFD9D3C5);
        canvas.drawPath(path, _casing);
      }
      _stroke
        ..strokeWidth = style.width
        ..color = style.color;
      canvas.drawPath(path, _stroke);
    }
  }

  int _maxClassForZoom(double z) {
    if (z < 7.2) return RoadGraph.cPrimary;
    if (z < 8.6) return RoadGraph.cSecondary;
    if (z < 10.5) return RoadGraph.cTertiary;
    if (z < 12.2) return RoadGraph.cUnclassified;
    if (z < 14.0) return RoadGraph.cResidential;
    return 255;
  }

  _RoadStyle _styleFor(int cls) {
    switch (cls) {
      case RoadGraph.cMotorway:
      case RoadGraph.cTrunk:
        return _RoadStyle(
            4.2, dark ? const Color(0xFFFFA733) : const Color(0xFFE8890C));
      case RoadGraph.cPrimary:
        return _RoadStyle(
            3.4, dark ? const Color(0xFFF5C661) : const Color(0xFFE0A21F));
      case RoadGraph.cSecondary:
        return _RoadStyle(
            2.5, dark ? const Color(0xFFE3D9B6) : const Color(0xFFC9A961));
      case RoadGraph.cTertiary:
        return _RoadStyle(
            1.8, dark ? const Color(0xFF9DB0C9) : const Color(0xFF9A9384));
      case RoadGraph.cUnclassified:
      case RoadGraph.cResidential:
      case RoadGraph.cLivingStreet:
        return _RoadStyle(
            1.05, dark ? const Color(0xFF6E7C93) : const Color(0xFFB4AE9F));
      default:
        return _RoadStyle(
            0.8, dark ? const Color(0xFF4C5768) : const Color(0xFFC9C3B4));
    }
  }

  @override
  bool shouldRepaint(covariant _RoadPainter oldWidget) => true;
}

// ---------------------------------------------------------------------------
// overlay layer
// ---------------------------------------------------------------------------

class _OverlayPainter extends CustomPainter {
  _OverlayPainter(Listenable cam, Listenable anim, this.proj)
      : super(repaint: Listenable.merge([cam, anim]));

  final _Projection proj;

  List<PoliceStation> stations = const [];
  List<PlaceLabel> places = const [];
  LatLng? userPoint;
  double? userAccuracy;
  double? userHeading;
  PoliceRoute? route;
  PoliceStation? focus;
  bool dark = true;

  final Map<String, TextPainter> _labels = {};

  @override
  void paint(Canvas canvas, Size s) {
    proj.sync();
    _paintPlaces(canvas, s);
    _paintRoute(canvas, s);
    _paintStations(canvas, s);
    _paintUser(canvas, s);
  }

  void _paintPlaces(Canvas canvas, Size s) {
    if (places.isEmpty) return;
    final minRank = switch (proj.zoom) {
      < 9 => 1,
      < 10.5 => 2,
      < 12 => 3,
      _ => 4,
    };
    final nLat = proj.latAt(0);
    final sLat = proj.latAt(s.height);
    final wLng = proj.lngAt(0);
    final eLng = proj.lngAt(s.width);
    for (final p in places) {
      if (p.rank > minRank) continue;
      if (p.lat < sLat || p.lat > nLat || p.lng < wLng || p.lng > eLng) continue;
      final o = proj.toScreen(p.lat, p.lng);
      final tp = _label(
        p.name,
        p.rank == 1 ? 15.0 : (p.rank == 2 ? 13.0 : 11.5),
        p.rank <= 2 ? FontWeight.w700 : FontWeight.w500,
        dark ? const Color(0xFFDCE6F5) : const Color(0xFF3A3A34),
        'p:${p.name}',
      );
      tp.paint(canvas, o - Offset(tp.width / 2, 0));
    }
  }

  void _paintRoute(Canvas canvas, Size s) {
    final r = route;
    if (r == null || r.geometry.length < 2) return;
    final path = ui.Path();
    var first = true;
    for (final p in r.geometry) {
      final o = proj.toScreen(p.latitude, p.longitude);
      if (first) {
        path.moveTo(o.dx, o.dy);
        first = false;
      } else {
        path.lineTo(o.dx, o.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 12
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0x332E7BFF),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0xFF0B0F18),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0xFF3D8BFF),
    );
  }

  void _paintStations(Canvas canvas, Size s) {
    if (stations.isEmpty) return;
    final showLabel = proj.zoom >= 13.6;
    final fill = Paint()..style = PaintingStyle.fill;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = const Color(0xFFEAF2FF);
    final cross = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    for (final st in stations) {
      final la = st.lat, lo = st.lng;
      if (la == null || lo == null) continue;
      final o = proj.toScreen(la, lo);
      if (o.dx < -40 ||
          o.dy < -40 ||
          o.dx > s.width + 40 ||
          o.dy > s.height + 40) {
        continue;
      }
      final isFocus = focus != null && focus!.id == st.id;
      final r = isFocus ? 9.0 : 6.5;
      if (isFocus) {
        canvas.drawCircle(
          o,
          r + 8,
          Paint()..color = const Color(0x332E7BFF),
        );
      }
      fill.color = const Color(0xFF1E6BFF);
      canvas.drawCircle(o, r, fill);
      canvas.drawCircle(o, r, ring);
      canvas.drawLine(o - Offset(r * 0.42, 0), o + Offset(r * 0.42, 0), cross);
      canvas.drawLine(o - Offset(0, r * 0.42), o + Offset(0, r * 0.42), cross);

      if (showLabel && isFocus) {
        final tp = _label(
          st.name,
          11.5,
          FontWeight.w700,
          Colors.white,
          'st:${st.id}',
          shadow: true,
        );
        tp.paint(canvas, o + Offset(r + 6, -tp.height / 2));
      }
    }
  }

  void _paintUser(Canvas canvas, Size s) {
    final p = userPoint;
    if (p == null) return;
    final o = proj.toScreen(p.latitude, p.longitude);
    final acc = userAccuracy;
    if (acc != null && acc > 0 && proj.zoom >= 12) {
      final metresPerPx =
          156543.03392 * math.cos(p.latitude * math.pi / 180) / proj.world;
      final r = (acc / metresPerPx).clamp(8.0, 400.0);
      canvas.drawCircle(o, r, Paint()..color = const Color(0x223D8BFF));
      canvas.drawCircle(
        o,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0x553D8BFF),
      );
    }
    canvas.drawCircle(o, 8.5, Paint()..color = const Color(0xFF0B0F18));
    canvas.drawCircle(o, 6.5, Paint()..color = const Color(0xFF2E7BFF));
    final h = userHeading;
    if (h != null) {
      final rad = (h - 90) * math.pi / 180.0;
      final tip = o + Offset(math.cos(rad), math.sin(rad)) * 15;
      canvas.drawCircle(tip, 3, Paint()..color = const Color(0xFFEAF2FF));
    }
  }

  TextPainter _label(
    String text,
    double size,
    FontWeight weight,
    Color color,
    String key, {
    bool shadow = false,
  }) {
    return _labels.putIfAbsent(key, () {
      return TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: size,
            fontWeight: weight,
            color: color,
            shadows: shadow
                ? const [Shadow(color: Color(0xDD000000), blurRadius: 5)]
                : (dark
                    ? const [Shadow(color: Color(0xCC000000), blurRadius: 4)]
                    : null),
          ),
        ),
        textDirection: ui.TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: 200);
    });
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter oldWidget) => true;
}

class _RoadStyle {
  const _RoadStyle(this.width, this.color);
  final double width;
  final Color color;
}
