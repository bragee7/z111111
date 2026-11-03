import { useState, useEffect, useCallback } from 'react';
import { Link } from 'react-router-dom';
import { adminAPI } from '../services/api';

const AdminCases = () => {
  const [cases, setCases] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [filter, setFilter] = useState('');
  const [lastUpdated, setLastUpdated] = useState(null);

  const loadCases = useCallback(async (silent = false) => {
    if (!silent) setLoading(true);
    try {
      const params = filter ? { status: filter } : {};
      const response = await adminAPI.getCases(params);
      setCases(response.data.cases);
      setLastUpdated(new Date());
      setError('');
    } catch (err) {
      setError('Failed to load cases');
    } finally {
      if (!silent) setLoading(false);
    }
  }, [filter]);

  useEffect(() => {
    loadCases();
    const interval = setInterval(() => loadCases(true), 60000);
    return () => clearInterval(interval);
  }, [loadCases]);

  const formatDate = (ts) => {
    if (!ts) return '—';
    return new Date(ts).toLocaleString('en-US', {
      year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit'
    });
  };

  if (loading) {
    return (
      <div className="min-h-screen bg-gray-900 flex items-center justify-center">
        <div className="animate-spin rounded-full h-16 w-16 border-t-4 border-purple-500"></div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-gray-900 p-6">
      <div className="max-w-7xl mx-auto">
        <div className="flex items-center justify-between mb-6">
          <div>
            <h1 className="text-3xl font-bold text-white">All SOS Cases</h1>
            <p className="text-sm text-gray-400 mt-1">
              Auto-refresh every 60s
              {lastUpdated ? ` · last checked ${lastUpdated.toLocaleTimeString()}` : ''}
            </p>
          </div>
          <div className="flex gap-2">
            {[
              { label: 'All', value: '' },
              { label: 'Pending', value: 'Pending' },
              { label: 'Resolved', value: 'Resolved' }
            ].map((f) => (
              <button
                key={f.value}
                onClick={() => setFilter(f.value)}
                className={`px-4 py-2 rounded-lg font-medium transition-colors ${
                  filter === f.value
                    ? 'bg-purple-600 text-white'
                    : 'bg-gray-800 text-gray-400 hover:bg-gray-700'
                }`}
              >
                {f.label}
              </button>
            ))}
          </div>
        </div>

        {error && (
          <div className="bg-red-900 border border-red-700 text-red-200 px-6 py-4 rounded-lg mb-6">
            {error}
          </div>
        )}

        <div className="bg-gray-800 rounded-xl overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-gray-400 border-b border-gray-700">
                <th className="py-4 px-6">Status</th>
                <th className="py-4 px-6">User</th>
                <th className="py-4 px-6">Time</th>
                <th className="py-4 px-6">Trigger</th>
                <th className="py-4 px-6">Media</th>
                <th className="py-4 px-6">Notes</th>
                <th className="py-4 px-6 text-right">Actions</th>
              </tr>
            </thead>
            <tbody>
              {cases.map((c) => (
                <tr key={c.id} className="border-b border-gray-700/50 hover:bg-gray-700/30">
                  <td className="py-4 px-6">
                    <span className={`px-3 py-1 rounded-full text-xs font-semibold ${
                      c.status === 'Pending'
                        ? 'bg-red-900 text-red-200'
                        : 'bg-green-900 text-green-200'
                    }`}>
                      {c.status}
                    </span>
                  </td>
                  <td className="py-4 px-6 text-gray-300">{c.userEmail || '—'}</td>
                  <td className="py-4 px-6 text-gray-400">{formatDate(c.createdAt)}</td>
                  <td className="py-4 px-6 text-gray-300 capitalize">{c.triggerType || 'Manual'}</td>
                  <td className="py-4 px-6">
                    <div className="flex gap-1">
                      {c.videoUrl && <span className="text-xs bg-gray-700 text-gray-300 px-2 py-1 rounded">🎥 Video</span>}
                      {c.audioUrl && <span className="text-xs bg-gray-700 text-gray-300 px-2 py-1 rounded">🎙 Audio</span>}
                      {!c.videoUrl && !c.audioUrl && <span className="text-gray-600">—</span>}
                    </div>
                  </td>
                  <td className="py-4 px-6 text-gray-400 max-w-xs truncate">{c.notes || '—'}</td>
                  <td className="py-4 px-6 text-right">
                    <Link
                      to={`/case/${c.id}`}
                      className="text-purple-400 hover:text-purple-300 font-medium transition-colors"
                    >
                      View →
                    </Link>
                  </td>
                </tr>
              ))}
              {cases.length === 0 && (
                <tr>
                  <td colSpan={7} className="py-10 text-center text-gray-500">No cases found</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
};

export default AdminCases;