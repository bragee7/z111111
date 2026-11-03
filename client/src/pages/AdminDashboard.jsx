import { useState, useEffect, useCallback, useRef } from 'react';
import { Link } from 'react-router-dom';
import { adminAPI } from '../services/api';
import { useEmergencyAlert } from '../hooks/useEmergencyAlert';
import DashboardChart from '../components/admin/DashboardChart';
import RefreshButton from '../components/admin/RefreshButton';
import DetailDrawer from '../components/admin/DetailDrawer';
import UsersPanel from './admin/UsersPanel';
import CasesPanel from './admin/CasesPanel';
import PendingPanel from './admin/PendingPanel';
import ResolvedPanel from './admin/ResolvedPanel';
import TodayCasesPanel from './admin/TodayCasesPanel';
import TodayUsersPanel from './admin/TodayUsersPanel';
import ContactsPanel from './admin/ContactsPanel';
import AuditEntriesPanel from './admin/AuditEntriesPanel';
import ResponseTimesPanel from './admin/ResponseTimesPanel';
import OfficerKpisPanel from './admin/OfficerKpisPanel';
import HeatmapView from '../components/HeatmapView';

const StatCard = ({ label, value, icon, accent, onClick, ariaLabel }) => {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-label={ariaLabel || `View ${label}`}
      className={`bg-gray-800 rounded-xl p-6 border-t-4 ${accent} text-left transition-all duration-200 hover:-translate-y-1 hover:shadow-lg hover:shadow-black/40 active:scale-[0.98] focus:outline-none focus:ring-2 focus:ring-white/30 cursor-pointer w-full`}
    >
      <div className="flex items-center justify-between">
        <div className="min-w-0">
          <p className="text-gray-400 text-sm font-medium">{label}</p>
          <p className="text-4xl font-bold text-white mt-2">{value}</p>
        </div>
        <div className={`w-12 h-12 rounded-full flex items-center justify-center ${icon?.bg ?? 'bg-gray-700'} shrink-0`}>
          <svg className={`w-6 h-6 ${icon?.color ?? 'text-gray-400'} fill-none stroke-currentColor`} viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d={icon?.path ?? 'M12 12h.01'} />
          </svg>
        </div>
      </div>
    </button>
  );
};

const STAT_ICONS = {
  users: {
    bg: 'bg-purple-900/50', color: 'text-purple-400',
    path: 'M17 20h5v-2a3 3 0 00-5.356-1.857M17 20H7m10 0v-2c0-.656-.126-1.283-.356-1.857M7 20H2v-2a3 3 0 015.356-1.857M7 20v-2c0-.656.126-1.283.356-1.857m0 0a5.002 5.002 0 019.288 0M15 7a3 3 0 11-6 0 3 3 0 016 0zm6 3a2 2 0 11-4 0 2 2 0 014 0zM7 10a2 2 0 11-4 0 2 2 0 014 0z',
  },
  cases: {
    bg: 'bg-red-900/50', color: 'text-red-400',
    path: 'M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z',
  },
  pending: {
    bg: 'bg-yellow-900/50', color: 'text-yellow-400',
    path: 'M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z',
  },
  resolved: {
    bg: 'bg-green-900/50', color: 'text-green-400',
    path: 'M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z',
  },
  casesToday: {
    bg: 'bg-pink-900/50', color: 'text-pink-400',
    path: 'M13 10V3L4 14h7v7l9-11h-7z',
  },
  usersToday: {
    bg: 'bg-blue-900/50', color: 'text-blue-400',
    path: 'M18 9v3m0 0v3m0-3h3m-3 0h-3m-2-5a4 4 0 11-8 0 4 4 0 018 0zM3 20a6 6 0 0112 0v1H3v-1z',
  },
  contacts: {
    bg: 'bg-teal-900/50', color: 'text-teal-400',
    path: 'M17 20h5v-2a3 3 0 00-5.356-1.857M17 20H7m10 0v-2c0-.656-.126-1.283-.356-1.857M7 20H2v-2a3 3 0 015.356-1.857M7 20v-2c0-.656.126-1.283.356-1.857m0 0a5.002 5.002 0 019.288 0M15 7a3 3 0 11-6 0 3 3 0 016 0zm6 3a2 2 0 11-4 0 2 2 0 014 0zM7 10a2 2 0 11-4 0 2 2 0 014 0z',
  },
  auditEntries: {
    bg: 'bg-indigo-900/50', color: 'text-indigo-400',
    path: 'M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2m-6 9l2 2 4-4',
  },
  responseTimes: {
    bg: 'bg-cyan-900/50', color: 'text-cyan-400',
    path: 'M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z',
  },
  officerKpis: {
    bg: 'bg-purple-900/50', color: 'text-purple-400',
    path: 'M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z',
  },
};

const PANELS = {
  users: { Component: UsersPanel, title: 'All Registered Users' },
  cases: { Component: CasesPanel, title: 'All SOS Cases' },
  pending: { Component: PendingPanel, title: 'Pending Cases' },
  resolved: { Component: ResolvedPanel, title: 'Resolved Cases' },
  casesToday: { Component: TodayCasesPanel, title: "Today's Cases" },
  usersToday: { Component: TodayUsersPanel, title: "Today's New Users" },
  contacts: { Component: ContactsPanel, title: 'Contacts Management' },
    auditEntries: { Component: AuditEntriesPanel, title: 'Audit Logs' },
    responseTimes: { Component: ResponseTimesPanel, title: 'Response Times' },
    officerKpis: { Component: OfficerKpisPanel, title: 'Officer KPIs' },
  };

function AdminDashboard() {
  const [overview, setOverview] = useState(null);
  const [registrations, setRegistrations] = useState([]);
  const [casesByDay, setCasesByDay] = useState([]);
  const [casesByUser, setCasesByUser] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [refreshing, setRefreshing] = useState(false);
  const [selectedSection, setSelectedSection] = useState(null);
  const [statusDist, setStatusDist] = useState([]);
  const [geoPoints, setGeoPoints] = useState([]);
  const [seriesPeriod, setSeriesPeriod] = useState('week');
  const [seriesData, setSeriesData] = useState([]);
  const [lastUpdated, setLastUpdated] = useState(null);
  const pendingIdsRef = useRef(null);
  const {
    alertActive: newAlert,
    audioReady,
    triggerAlert,
    dismissAlert,
    ensureAudio,
  } = useEmergencyAlert(10000);

  const loadData = useCallback(async () => {
    try {
      const [ov, reg, cbd, cbu, sd, geo, sdata, pendingRes] = await Promise.all([
        adminAPI.getOverview(),
        adminAPI.getRegistrations(30),
        adminAPI.getCasesByDay(30),
        adminAPI.getCasesByUser(),
        adminAPI.getStatusDistribution(),
        adminAPI.getGeo(),
        adminAPI.getSeries(seriesPeriod),
        adminAPI.getCases({ status: 'Pending', page: 1, size: 100 }),
      ]);
      const pendingCases = pendingRes.data.cases || [];
      const nextPendingIds = new Set(pendingCases.map((item) => item.id));
      const knownPendingIds = pendingIdsRef.current;
      const hasNewPending = knownPendingIds
        && pendingCases.some((item) => !knownPendingIds.has(item.id));
      pendingIdsRef.current = nextPendingIds;
      if (hasNewPending) triggerAlert();

      setOverview(ov.data);
      setRegistrations(reg.data.series || []);
      setCasesByDay(cbd.data.series || []);
      setCasesByUser(cbu.data.users || []);
      setStatusDist(sd.data.distribution || []);
      setGeoPoints(geo.data.points || []);
      setSeriesData(sdata.data.series || []);
      setLastUpdated(new Date());
      setError('');
    } catch (e) {
      setError('Failed to load dashboard data. Please try again.');
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, [seriesPeriod, triggerAlert]);

  useEffect(() => {
    loadData();
    const interval = setInterval(loadData, 60000);
    return () => clearInterval(interval);
  }, [loadData]);

  const handleRefresh = () => {
    setRefreshing(true);
    loadData();
  };

  const handlePeriodChange = async (period) => {
    setSeriesPeriod(period);
    try {
      const res = await adminAPI.getSeries(period);
      setSeriesData(res.data.series || []);
    } catch (e) {
      setError('Failed to load case trend data.');
    }
  };

  const statusColors = {
    Pending: 'bg-yellow-500',
    Resolved: 'bg-green-500',
    Assigned: 'bg-blue-500',
    Closed: 'bg-red-500',
  };
  const maxStatusCount = Math.max(...statusDist.map((s) => Number(s.count) || 0), 1);

  if (loading) {
    return (
      <div className="min-h-screen bg-gray-900 flex items-center justify-center">
        <div className="animate-spin rounded-full h-16 w-16 border-t-4 border-purple-500"></div>
      </div>
    );
  }

  const statCards = [
    { key: 'users', label: 'Total Users', value: overview?.totalUsers ?? 0, accent: 'border-purple-500', section: 'users' },
    { key: 'cases', label: 'Total Cases', value: overview?.totalCases ?? 0, accent: 'border-red-500', section: 'cases' },
    { key: 'pending', label: 'Pending', value: overview?.pendingCases ?? 0, accent: 'border-yellow-500', section: 'pending' },
    { key: 'resolved', label: 'Resolved', value: overview?.resolvedCases ?? 0, accent: 'border-green-500', section: 'resolved' },
    { key: 'casesToday', label: 'Cases Today', value: overview?.casesToday ?? 0, accent: 'border-pink-500', section: 'casesToday' },
    { key: 'usersToday', label: 'Users Today', value: overview?.usersToday ?? 0, accent: 'border-blue-500', section: 'usersToday' },
    { key: 'contacts', label: 'Contacts', value: overview?.totalContacts ?? 0, accent: 'border-teal-500', section: 'contacts' },
    { key: 'auditEntries', label: 'Audit Entries', value: overview?.auditCount ?? 0, accent: 'border-indigo-500', section: 'auditEntries' },
    { key: 'responseTimes', label: 'Response Times', value: overview?.avgResponseMinutes ?? 0, accent: 'border-cyan-500', section: 'responseTimes' },
    { key: 'officerKpis', label: 'Officer KPIs', value: 0, accent: 'border-purple-500', section: 'officerKpis' },
  ];

  const topUsers = casesByUser.slice(0, 10);
  const maxCases = Math.max(...topUsers.map((u) => u.case_count), 1);

  const ActivePanel = selectedSection ? PANELS[selectedSection] : null;

  return (
    <div className="min-h-screen bg-gray-900 p-6">
      <div className="max-w-7xl mx-auto">
        <div className="flex flex-wrap items-center justify-between gap-4 mb-2">
          <h1 className="text-3xl font-bold text-white">Admin Dashboard</h1>
          <div className="flex items-center gap-3">
            {!audioReady && (
              <button
                type="button"
                onClick={ensureAudio}
                className="bg-yellow-600 hover:bg-yellow-500 text-white text-sm font-semibold px-4 py-2 rounded-lg transition-colors"
              >
                🔔 Enable alarm sound
              </button>
            )}
            <RefreshButton onClick={handleRefresh} loading={refreshing} label="⟳ Refresh" />
          </div>
        </div>

        <p className="text-sm text-gray-400 mb-6">
          Auto-refresh every 60s
          {lastUpdated ? ` · last checked ${lastUpdated.toLocaleTimeString()}` : ''}
        </p>

        {newAlert && (
          <button
            type="button"
            onClick={dismissAlert}
            className="w-full bg-red-600 hover:bg-red-500 text-white px-6 py-4 rounded-lg mb-6 text-left transition-colors animate-pulse"
          >
            <span className="text-lg font-bold">🚨 NEW EMERGENCY ALERT RECEIVED! 🚨</span>
            <span className="block text-sm text-red-100 mt-1">A new SOS case is pending. Tap to dismiss.</span>
          </button>
        )}

        {error && (
          <div className="bg-red-900 border border-red-700 text-red-200 px-6 py-4 rounded-lg mb-6">
            {error}
          </div>
        )}

        <div className="grid grid-cols-2 md:grid-cols-4 gap-6 mb-8">
          {statCards.map((card) => (
            <StatCard
              key={card.key}
              label={card.label}
              value={card.value}
              icon={STAT_ICONS[card.section]}
              accent={card.accent}
              onClick={() => setSelectedSection(card.section)}
            />
          ))}
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6 mb-8">
          <DashboardChart
            title="New User Registrations (30 days)"
            series={registrations}
            color="bg-purple-500"
            label="New Users"
          />
          <DashboardChart
            title="Cases Created Per Day (30 days)"
            series={casesByDay}
            color="bg-red-500"
            label="Cases"
          />
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6 mb-8">
          <div className="bg-gray-800 rounded-xl p-6">
            <h3 className="text-xl font-semibold text-white mb-6">Cases by Status</h3>
            <div className="space-y-4">
              {statusDist.length === 0 && (
                <p className="text-gray-400 text-sm">No case data available.</p>
              )}
              {statusDist.map((s) => (
                <div key={s.status}>
                  <div className="flex items-center justify-between mb-1">
                    <span className="text-sm text-gray-300 font-medium">{s.status}</span>
                    <span className="text-white font-bold">{s.count}</span>
                  </div>
                  <div className="w-full bg-gray-700 rounded-full h-2">
                    <div
                      className={`${statusColors[s.status] || 'bg-purple-500'} h-2 rounded-full`}
                      style={{ width: `${(Number(s.count) / maxStatusCount) * 100}%` }}
                    />
                  </div>
                </div>
              ))}
            </div>
          </div>
          <div className="bg-gray-800 rounded-xl p-6">
            <div className="flex items-center justify-between mb-6">
              <h3 className="text-xl font-semibold text-white">Case Trend</h3>
              <div className="flex gap-2">
                <button
                  type="button"
                  onClick={() => handlePeriodChange('week')}
                  className={`px-3 py-1 text-sm rounded-lg transition-colors ${
                    seriesPeriod === 'week'
                      ? 'bg-purple-500 text-white'
                      : 'bg-gray-700 text-gray-300 hover:bg-gray-600'
                  }`}
                >
                  Weekly
                </button>
                <button
                  type="button"
                  onClick={() => handlePeriodChange('month')}
                  className={`px-3 py-1 text-sm rounded-lg transition-colors ${
                    seriesPeriod === 'month'
                      ? 'bg-purple-500 text-white'
                      : 'bg-gray-700 text-gray-300 hover:bg-gray-600'
                  }`}
                >
                  Monthly
                </button>
              </div>
            </div>
            <DashboardChart
              title={`Cases by ${seriesPeriod === 'month' ? 'Month' : 'Week'}`}
              series={seriesData}
              color="bg-cyan-500"
              label="Cases"
            />
          </div>
        </div>

        <div className="bg-gray-800 rounded-xl p-6 mb-8">
          <h3 className="text-xl font-semibold text-white mb-6">Case Heatmap</h3>
          <HeatmapView points={geoPoints} height="h-96" emptyText="No geolocated cases available" />
        </div>

        <div className="bg-gray-800 rounded-xl p-6">
          <div className="flex items-center justify-between mb-6">
            <h3 className="text-xl font-semibold text-white">Cases Created Per User</h3>
            <Link to="/admin/users" className="text-purple-400 hover:text-purple-300 text-sm font-medium">
              Manage Users →
            </Link>
          </div>
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-gray-400 border-b border-gray-700">
                  <th className="py-3 pr-4">User</th>
                  <th className="py-3 pr-4">Guardian Email</th>
                  <th className="py-3">Cases</th>
                </tr>
              </thead>
              <tbody>
                {topUsers.map((u) => (
                  <tr key={u.user_id} className="border-b border-gray-700/50">
                    <td className="py-3 pr-4 text-white font-medium">{u.name || '—'}</td>
                    <td className="py-3 pr-4 text-gray-300">{u.email}</td>
                    <td className="py-3">
                      <div className="flex items-center gap-2">
                        <div className="w-24 bg-gray-700 rounded-full h-2">
                          <div
                            className="bg-purple-500 h-2 rounded-full"
                            style={{ width: `${(u.case_count / maxCases) * 100}%` }}
                          />
                        </div>
                        <span className="text-white font-semibold">{u.case_count}</span>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      </div>

      {ActivePanel && (
        <DetailDrawer
          title={ActivePanel.title}
          subtitle={`${statCards.find((c) => c.section === selectedSection)?.label ?? ''} — Overview`}
          onClose={() => setSelectedSection(null)}
        >
          <ActivePanel.Component onClose={() => setSelectedSection(null)} title={ActivePanel.title} />
        </DetailDrawer>
      )}
    </div>
  );
}

export default AdminDashboard;