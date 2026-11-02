import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme.dart';
import '../models/police_station.dart';
import '../state/police_stations_provider.dart';
import '../widgets/police_station_card.dart';
import '../widgets/police_station_map.dart';

/// Police-station directory: nearby, all stations, map, district helplines.
class PoliceStationsScreen extends StatefulWidget {
  const PoliceStationsScreen({super.key});

  @override
  State<PoliceStationsScreen> createState() => _PoliceStationsScreenState();
}

class _PoliceStationsScreenState extends State<PoliceStationsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<PoliceStationsProvider>().load();
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ps = context.watch<PoliceStationsProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Police Stations'),
        backgroundColor: AppColors.policeBlue,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: ps.following ? 'Stop following' : 'Follow me',
            icon: Icon(ps.following
                ? Icons.gps_fixed
                : Icons.gps_not_fixed),
            color: ps.following ? AppColors.safeLight : Colors.white,
            onPressed: () {
              if (ps.following) {
                ps.stopFollowing();
              } else {
                ps.startFollowing();
              }
            },
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: AppColors.amber300,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          onTap: (i) => ps.setTab(PsTab.values[i]),
          tabs: const [
            Tab(text: 'Nearby'),
            Tab(text: 'All Stations'),
            Tab(text: 'Map'),
            Tab(text: 'Districts'),
          ],
        ),
      ),
      body: ps.status == PsStatus.loading
          ? const Center(child: CircularProgressIndicator())
          : ps.status == PsStatus.error && ps.all.isEmpty
              ? _errorPane(ps.error)
              : Column(
                  children: [
                    Container(width: double.infinity, color: AppColors.amber300, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8), child: Row(children: [const Icon(Icons.offline_bolt, size: 15, color: Colors.black87), const SizedBox(width: 6), Expanded(child: Text(ps.hasOfflineRouter ? '100% offline - bundled map and on-device routing (${_fmtCount(ps.graphStats.nodes)} roads).' : 'Offline directory. The bundled road map is still loading...', style: const TextStyle(fontSize: 11.5, color: Colors.black87, fontWeight: FontWeight.w600)))]),),
                    if (ps.error.isNotEmpty) _errorStrip(ps.error),
                    Expanded(
                      child: TabBarView(
                        controller: _tabs,
                        children: [
                          _nearbyTab(ps),
                          _allTab(ps),
                          _mapTab(ps),
                          _districtsTab(ps),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }

  // ------------------------------------------------------------- chrome
  Widget _errorStrip(String message) {
    return Container(
      width: double.infinity,
      color: AppColors.red50,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Text(
        message,
        style: const TextStyle(fontSize: 12, color: AppColors.red700),
      ),
    );
  }

  Widget _errorPane(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 46, color: AppColors.gray400),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AppColors.gray600),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () =>
                  context.read<PoliceStationsProvider>().load(force: true),
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- nearby
  Widget _nearbyTab(PoliceStationsProvider ps) {
    if (ps.nearby.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Text(
            'No nearby stations yet — allow location access and pull to refresh.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppColors.gray500),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: ps.nearby.length,
      separatorBuilder: (_, _) => const SizedBox(height: 9),
      itemBuilder: (_, i) {
        final s = ps.nearby[i];
        return PoliceStationCard(
          station: s,
          onRoute: () => ps.routeTo(s),
          onDirections: () {
            ps.startFollowing();
            ps.routeTo(s);
          },
          onShowOnMap: () => _showOnMap(ps, s),
        );
      },
    );
  }

  // ---------------------------------------------------------------- all
  Widget _allTab(PoliceStationsProvider ps) {
    final list = ps.filtered;
    return Column(
      children: [
        _searchBar(ps),
        if (ps.districtNames.isNotEmpty) _chips(ps),
        Expanded(
          child: list.isEmpty
              ? const Center(
                  child: Text(
                    'No stations matched your search.',
                    style: TextStyle(fontSize: 13, color: AppColors.gray500),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final s = list[i];
                    return PoliceStationCard(
                      station: s,
                      compact: true,
                      onRoute: s.hasCoords ? () => ps.routeTo(s) : null,
                      onDirections: s.hasCoords
                          ? () {
                              ps.startFollowing();
                              ps.routeTo(s);
                            }
                          : null,
                      onShowOnMap: s.hasCoords ? () => _showOnMap(ps, s) : null,
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _searchBar(PoliceStationsProvider ps) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _search,
              onChanged: ps.setQuery,
              style: const TextStyle(fontSize: 13.5),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search name, district, id…',
                hintStyle: const TextStyle(fontSize: 13, color: AppColors.gray400),
                prefixIcon: const Icon(Icons.search,
                    size: 19, color: AppColors.gray400),
                suffixIcon: ps.query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 17),
                        onPressed: () {
                          _search.clear();
                          ps.setQuery('');
                        },
                      ),
                filled: true,
                fillColor: AppColors.gray50,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.gray200),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.gray200),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: ps.sortByDistance ? 'Sort by distance' : 'Sort by name',
            onPressed: ps.toggleSort,
            style: IconButton.styleFrom(
              backgroundColor: AppColors.gray50,
              side: const BorderSide(color: AppColors.gray200),
            ),
            icon: Icon(
              ps.sortByDistance ? Icons.near_me : Icons.sort_by_alpha,
              size: 19,
              color: AppColors.gray700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _chips(PoliceStationsProvider ps) {
    return Container(
      color: Colors.white,
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: ps.districtNames.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 7),
        itemBuilder: (_, i) {
          if (i == 0) {
            final on = ps.districtFilter.isEmpty;
            return _chip('All', on, () => ps.setDistrictFilter(''));
          }
          final d = ps.districtNames[i - 1];
          final on = ps.districtFilter == d;
          return _chip(d, on, () => ps.setDistrictFilter(d));
        },
      ),
    );
  }

  Widget _chip(String label, bool on, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: on ? AppColors.policeBlue : AppColors.gray50,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: on ? AppColors.policeBlue : AppColors.gray200,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: on ? Colors.white : AppColors.gray600,
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- map
  Widget _mapTab(PoliceStationsProvider ps) {
    final stations = ps.route != null && ps.routeDestination != null
        ? ps.nearby
        : (ps.nearby.isNotEmpty ? ps.nearby : ps.filtered);

    return Stack(
      children: [
        Positioned.fill(
          child: PoliceStationMap(
            stations: stations,
            highlight: ps.routeDestination,
            userPoint: ps.userPoint,
            userAccuracy: ps.userAccuracy,
            route: ps.route,
            followUser: ps.following,
            pickMode: false,
            onStationTap: (s) => _openStationSheet(ps, s),
          ),
        ),
        // travel mode + route action
        Positioned(
          left: 12,
          top: 12,
          right: 12,
          child: Row(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x22000000),
                      blurRadius: 6,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final m in const [
                      ('auto', '🚗', 'Drive'),
                      ('walk', '🚶', 'Walk'),
                      ('bike', '🚲', 'Bike'),
                    ])
                      GestureDetector(
                        onTap: () => ps.setMode(m.$1),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: ps.mode == m.$1
                                ? AppColors.policeBlue
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            m.$2,
                            style: TextStyle(
                              fontSize: 14,
                              color: ps.mode == m.$1
                                  ? Colors.white
                                  : AppColors.gray600,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const Spacer(),
              if (ps.route == null)
                Material(
                  color: AppColors.emergencyRed,
                  borderRadius: BorderRadius.circular(10),
                  elevation: 3,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: ps.routing ? null : ps.routeToNearest,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                          horizontal: 13, vertical: 10),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.route, size: 17, color: Colors.white),
                          SizedBox(width: 7),
                          Text(
                            'Nearest route',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (ps.routing)
          Container(
            color: Colors.black26,
            child: const Center(child: CircularProgressIndicator()),
          ),
        if (ps.route != null) _routeSheet(ps),
        if (ps.offRoute)
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.amber300,
                borderRadius: BorderRadius.circular(11),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, size: 18, color: Colors.black87),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'You have left the route — recalculating…',
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
      ],
    );
  }

  Widget _routeSheet(PoliceStationsProvider ps) {
    final r = ps.route!;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.55,
        ),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.gray300,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ps.routeDestination?.name ?? 'Police Station',
                          style: const TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.gray900,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${r.distanceLabel}  •  ${r.minutes} min  •  arrive ${r.etaLabel}',
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: AppColors.gray600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: ps.following ? 'Stop following' : 'Follow route',
                    onPressed: () {
                      if (ps.following) {
                        ps.stopFollowing();
                      } else {
                        ps.startFollowing();
                      }
                    },
                    icon: Icon(
                      ps.following
                          ? Icons.my_location
                          : Icons.near_me_outlined,
                      size: 19,
                      color: ps.following ? AppColors.emergencyRed : null,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Clear route',
                    onPressed: ps.clearRoute,
                    icon: const Icon(Icons.close, size: 19),
                  ),
                ],
              ),
            ),
            if (r.steps.isNotEmpty)
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                  itemCount: r.steps.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final s = r.steps[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 7),
                      child: Row(
                        children: [
                          Text(s.icon, style: const TextStyle(fontSize: 15)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              s.instruction,
                              style: const TextStyle(
                                fontSize: 12.5,
                                color: AppColors.gray800,
                                height: 1.3,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            s.distanceLabel,
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.gray500,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ----------------------------------------------------------- districts
  Widget _districtsTab(PoliceStationsProvider ps) {
    if (ps.districts.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Text(
            'District helplines are not available right now.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppColors.gray500),
          ),
        ),
      );
    }
    final q = ps.query.trim().toLowerCase();
    final list = q.isEmpty
        ? ps.districts
        : ps.districts
            .where((d) => d.district.toLowerCase().contains(q))
            .toList();

    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: list.length,
      separatorBuilder: (_, _) => const SizedBox(height: 9),
      itemBuilder: (_, i) {
        final d = list[i];
        final num = d.callNumber;
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.gray200),
          ),
          padding: const EdgeInsets.all(13),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.policeLight.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.phone_in_talk,
                    color: AppColors.policeBlue, size: 19),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      d.district,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.gray900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      d.displayLandline,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.gray500,
                      ),
                    ),
                  ],
                ),
              ),
              if (num != null)
                IconButton(
                  tooltip: 'Call $num',
                  onPressed: () => _launch('tel:$num'),
                  style: IconButton.styleFrom(
                    backgroundColor: AppColors.safeGreen.withValues(alpha: 0.12),
                  ),
                  icon: const Icon(Icons.call,
                      color: AppColors.safeGreen, size: 20),
                ),
            ],
          ),
        );
      },
    );
  }

  static Future<void> _launch(String url) async {
    try {
      final uri = Uri.parse(url);
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      /* ignore */
    }
  }

  // ----------------------------------------------------------- utilities
  void _showOnMap(PoliceStationsProvider ps, PoliceStation s) {
    ps.setTab(PsTab.map);
    _tabs.animateTo(2);
  }

  void _openStationSheet(PoliceStationsProvider ps, PoliceStation s) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 18),
        child: PoliceStationCard(
          station: s,
          onRoute: () {
            Navigator.pop(ctx);
            ps.routeTo(s);
          },
          onDirections: () {
            Navigator.pop(ctx);
            ps.startFollowing();
            ps.routeTo(s);
          },
        ),
      ),
    );
  }

  /// 12345 -> "12,345"
  static String _fmtCount(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}
