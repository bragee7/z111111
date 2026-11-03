import { useState, useEffect, useCallback } from 'react';
import { adminAPI } from '../../services/api';
import DetailDrawer from '../../components/admin/DetailDrawer';
import DataTable from '../../components/admin/DataTable';
import SearchBar from '../../components/admin/SearchBar';
import FilterBar from '../../components/admin/FilterBar';
import Pagination from '../../components/admin/Pagination';
import LoadingState from '../../components/admin/LoadingState';
import EmptyState from '../../components/admin/EmptyState';
import ErrorState from '../../components/admin/ErrorState';
import RefreshButton from '../../components/admin/RefreshButton';
import CaseActions from '../../components/admin/CaseActions';
import { formatDateTime, shortId, truncate } from '../../utils/format';

const STATUS_COLORS = {
  Pending: 'bg-yellow-900/50 text-yellow-400',
  Resolved: 'bg-green-900/50 text-green-400',
};

const PRIORITY_COLORS = {
  High: 'bg-red-900/50 text-red-400',
  Medium: 'bg-yellow-900/50 text-yellow-400',
  Low: 'bg-green-900/50 text-green-400',
};

const CasesPanel = ({ onClose, title, fixedStatus, columns: overrideColumns }) => {
  const [data, setData] = useState({ total: 0, cases: [] });
  const [page, setPage] = useState(1);
  const [size, setSize] = useState(20);
  const [search, setSearch] = useState('');
  const [status, setStatus] = useState(fixedStatus || '');
  const [priority, setPriority] = useState('');
  const [dateRange, setDateRange] = useState('');
  const [today, setToday] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  const load = useCallback(async (silent = false) => {
    if (!silent) setLoading(true);
    setError('');
    try {
      const params = {
        page, size,
        search: search || undefined,
        status: status || undefined,
        priority: priority || undefined,
        today: today ? 1 : undefined,
      };
      if (dateRange === '7' || dateRange === '30') params.days = dateRange;
      const res = await adminAPI.getCases(params);
      setData({ total: res.data.total, cases: res.data.cases });
    } catch (e) {
      setError(e?.response?.data?.error || 'Failed to load cases');
    } finally {
      if (!silent) setLoading(false);
    }
  }, [page, size, search, status, priority, dateRange, today]);

  useEffect(() => {
    load();
    const interval = setInterval(() => load(true), 60000);
    return () => clearInterval(interval);
  }, [load]);

  const columns = overrideColumns || [
    { key: 'id', label: 'Case ID', render: (r) => <span className="text-gray-400 font-mono text-xs">{shortId(r.id)}</span> },
    { key: 'caseNumber', label: 'Case Number', render: () => '—' },
    { key: 'userEmail', label: 'User', render: (r) => <span className="text-white font-medium">{r.userEmail || '—'}</span> },
    { key: 'userEmail', label: 'User Email', render: (r) => <span className="text-gray-300">{r.userEmail || '—'}</span> },
    { key: 'createdAt', label: 'Created Date/Time', render: (r) => formatDateTime(r.createdAt) },
    { key: 'locationLink', label: 'Location', render: (r) => (r.locationLink ? <a href={r.locationLink} target="_blank" rel="noreferrer" className="text-purple-400 hover:text-purple-300 underline text-xs">View</a> : '—') },
    { key: 'caseType', label: 'Case Type', render: (r) => <span className="text-gray-300">{r.caseType || '—'}</span> },
    { key: 'priority', label: 'Priority', render: (r) => <span className={`px-2 py-1 rounded-full text-xs font-medium ${PRIORITY_COLORS[r.priority] || 'bg-gray-700 text-gray-300'}`}>{r.priority || '—'}</span> },
    { key: 'status', label: 'Status', render: (r) => <span className={`px-2 py-1 rounded-full text-xs font-medium ${STATUS_COLORS[r.status] || 'bg-gray-700 text-gray-300'}`}>{r.status || '—'}</span> },
    { key: 'assignedOfficer', label: 'Assigned Officer', render: (r) => <span className="text-gray-300">{r.assignedOfficer || '—'}</span> },
    { key: 'updatedAt', label: 'Last Updated', render: (r) => formatDateTime(r.updatedAt) },
  ];
  columns.push({ key: 'actions', label: 'Actions', render: (r) => <CaseActions row={r} onChanged={() => load()} /> });

  const filters = [];
  if (!fixedStatus) filters.push({ key: 'status', label: 'All Statuses', options: [{ value: 'Pending', label: 'Pending' }, { value: 'Resolved', label: 'Resolved' }] });
  filters.push({ key: 'priority', label: 'All Priorities', options: [{ value: 'High', label: 'High' }, { value: 'Medium', label: 'Medium' }, { value: 'Low', label: 'Low' }] });
  filters.push({ key: 'dateRange', label: 'Date', options: [{ value: '7', label: 'Last 7 Days' }, { value: '30', label: 'Last 30 Days' }] });

  return (
    <DetailDrawer title={title} subtitle={`Total Cases: ${data.total}`} onClose={onClose}>
      <div className="flex flex-wrap items-center gap-3 mb-4">
        <SearchBar placeholder="Search case ID, user, location..." onSearch={setSearch} />
        <FilterBar
          filters={filters}
          values={{ status, priority, dateRange }}
          onChange={(k, v) => { if (k === 'status') setStatus(v); if (k === 'priority') setPriority(v); if (k === 'dateRange') setDateRange(v); setPage(1); }}
        />
        {!fixedStatus && (
          <label className="inline-flex items-center gap-2 text-sm text-gray-300 cursor-pointer">
            <input type="checkbox" checked={today} onChange={(e) => { setToday(e.target.checked); setPage(1); }} className="accent-purple-500 w-4 h-4" />
            Today only
          </label>
        )}
        <RefreshButton onClick={() => load()} loading={loading} />
      </div>

      {error ? <ErrorState message={error} onRetry={() => load()} /> : loading ? <LoadingState label="Loading cases..." /> : data.cases.length === 0 ? <EmptyState title="No cases found" message="There are no cases matching the current filters." /> : (
        <>
          <DataTable columns={columns} rows={data.cases} rowKey="id" />
          <Pagination total={data.total} page={page} size={size} onPageChange={setPage} />
        </>
      )}
    </DetailDrawer>
  );
};

export default CasesPanel;