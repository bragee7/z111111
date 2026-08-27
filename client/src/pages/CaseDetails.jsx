import { useState, useEffect, useRef } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { sosAPI, getMediaUrl } from '../services/api';
import { useAuth } from '../context/AuthContext';
import { buildWhatsAppLink } from '../utils/share';
import MapView, { policeStationIcon } from '../components/MapView';

const CaseDetails = () => {
  const { id } = useParams();
  const navigate = useNavigate();
  const { user, isPolice, isAdmin } = useAuth();
  const canManage = isPolice || isAdmin;
  const [caseData, setCaseData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [notes, setNotes] = useState('');
  const [saving, setSaving] = useState(false);
  const [updating, setUpdating] = useState(false);
  const [phone, setPhone] = useState('');
  const [showClosure, setShowClosure] = useState(false);
  const [closureReason, setClosureReason] = useState('');
  const [customReason, setCustomReason] = useState('');
  const [timeline, setTimeline] = useState([]);
  const videoRef = useRef(null);
  const audioRef = useRef(null);

  useEffect(() => {
    fetchCase();
  }, [id]);

  useEffect(() => {
    sosAPI.getCaseTimeline(id)
      .then(r => setTimeline(r.data.timeline || []))
      .catch(() => setTimeline([]));
  }, [id]);

  const fetchCase = async () => {
    try {
      const response = await sosAPI.getCase(id);
      setCaseData(response.data.case);
      setNotes(response.data.case.notes || '');
      setLoading(false);
    } catch (err) {
      setError('Failed to load case details');
      setLoading(false);
    }
  };

  const handleStatusUpdate = async (newStatus, reason) => {
    setUpdating(true);
    try {
      await sosAPI.updateCase(id, { status: newStatus, notes, closureReason: reason });
      await fetchCase();
    } catch (err) {
      setError('Failed to update case');
    } finally {
      setUpdating(false);
    }
  };

  const CLOSURE_REASONS = ['False Alarm', 'Victim Safe', 'Police Intervention', 'Emergency Resolved', 'Duplicate Case', 'Other'];

  const confirmResolve = async () => {
    const reason = closureReason === 'Other' && customReason.trim()
      ? customReason.trim()
      : closureReason;
    if (!reason) {
      setError('A closure reason is required to resolve the case');
      return;
    }
    setShowClosure(false);
    setClosureReason('');
    setCustomReason('');
    await handleStatusUpdate('Resolved', reason);
  };

  const handleNotesUpdate = async () => {
    setSaving(true);
    try {
      await sosAPI.updateCase(id, { notes });
      await fetchCase();
    } catch (err) {
      setError('Failed to update notes');
    } finally {
      setSaving(false);
    }
  };

  const formatDate = (timestamp) => {
    const date = new Date(timestamp);
    return date.toLocaleString('en-US', {
      weekday: 'long',
      year: 'numeric',
      month: 'long',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit'
    });
  };

  const handleVideoError = () => {
    console.error('Video playback error');
  };

  const handleAudioError = () => {
    console.error('Audio playback error');
  };

  const generateReportHTML = () => {
    return `
      <!DOCTYPE html>
      <html>
      <head>
        <title>Emergency Case Report - ${caseData.id}</title>
        <style>
          * { margin: 0; padding: 0; box-sizing: border-box; }
          body { font-family: 'Segoe UI', Arial, sans-serif; padding: 48px; color: #1a1a1a; background: #fff; }
          .header { border-bottom: 3px solid #dc2626; padding-bottom: 16px; margin-bottom: 32px; }
          .header h1 { color: #dc2626; font-size: 28px; }
          .header .subtitle { color: #666; font-size: 14px; margin-top: 4px; }
          .section { margin-bottom: 28px; }
          .section h2 { color: #333; font-size: 18px; border-bottom: 1px solid #e5e7eb; padding-bottom: 8px; margin-bottom: 16px; }
          table { width: 100%; border-collapse: collapse; }
          table td { padding: 10px 12px; border-bottom: 1px solid #f3f4f6; }
          table td:first-child { width: 160px; color: #666; font-weight: 600; vertical-align: top; }
          table td:last-child { color: #1a1a1a; }
          .badge { display: inline-block; padding: 4px 12px; border-radius: 12px; font-size: 13px; font-weight: 600; }
          .badge-pending { background: #fef2f2; color: #dc2626; }
          .badge-resolved { background: #f0fdf4; color: #16a34a; }
          .footer { margin-top: 48px; padding-top: 16px; border-top: 1px solid #e5e7eb; font-size: 12px; color: #999; text-align: center; }
          .footer p { margin-top: 4px; }
          .map-link { color: #2563eb; text-decoration: underline; }
          @media print { body { padding: 24px; } }
        </style>
      </head>
      <body>
        <div class="header">
          <h1>Emergency Case Report</h1>
          <div class="subtitle">Women Safety Guardian - Incident Documentation</div>
        </div>

        <div class="section">
          <h2>Case Information</h2>
          <table>
            <tr><td>Case ID</td><td>${caseData.id}</td></tr>
            <tr><td>Status</td><td><span class="badge ${caseData.status === 'Pending' ? 'badge-pending' : 'badge-resolved'}">${caseData.status}</span></td></tr>
            <tr><td>Reporter</td><td>${caseData.userEmail || 'Unknown'}</td></tr>
            <tr><td>Reported At</td><td>${formatDate(caseData.timestamp)}</td></tr>
            <tr><td>Last Updated</td><td>${caseData.updatedAt ? formatDate(caseData.updatedAt) : formatDate(caseData.timestamp)}</td></tr>
            <tr><td>Trigger Type</td><td>${caseData.triggerType || 'Manual'}</td></tr>
          </table>
        </div>

        <div class="section">
          <h2>Location Details</h2>
          <table>
            <tr><td>Coordinates</td><td>${caseData.latitude ? `${caseData.latitude}, ${caseData.longitude}` : 'Not captured'}</td></tr>
            <tr><td>Google Maps</td><td>${caseData.locationLink ? `<a class="map-link" href="${caseData.locationLink}">${caseData.locationLink}</a>` : 'Not available'}</td></tr>
          </table>
        </div>

        <div class="section">
          <h2>Media Evidence</h2>
          <table>
            <tr><td>Video Recording</td><td>${caseData.videoUrl ? 'Captured' : 'Not available'}</td></tr>
            <tr><td>Audio Recording</td><td>${caseData.audioUrl ? 'Captured' : 'Not available'}</td></tr>
          </table>
        </div>

        <div class="section">
          <h2>Notes</h2>
          <p style="color: #333; line-height: 1.6;">${caseData.notes || 'No notes recorded'}</p>
        </div>

        <div class="footer">
          <p>Generated by Women Safety Guardian</p>
          <p>${new Date().toLocaleString()}</p>
          <p>This is a computer-generated report.</p>
        </div>
      </body>
      </html>
    `;
  };

  if (loading) {
    return (
      <div className="min-h-screen bg-gray-900 flex items-center justify-center">
        <div className="animate-spin rounded-full h-16 w-16 border-t-4 border-police-blue"></div>
      </div>
    );
  }

  if (!caseData) {
    return (
      <div className="min-h-screen bg-gray-900 flex items-center justify-center">
        <div className="text-center">
          <p className="text-white text-xl mb-4">Case not found</p>
          <button 
            onClick={() => navigate(-1)}
            className="bg-police-blue text-white px-6 py-2 rounded-lg hover:bg-blue-700"
          >
            Go Back
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-gray-900 p-6">
      <div className="max-w-6xl mx-auto">
        <div className="mb-6">
          <button 
            onClick={() => navigate(-1)}
            className="text-gray-400 hover:text-white flex items-center space-x-2"
          >
            <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 19l-7-7 7-7" />
            </svg>
            <span>Back to Dashboard</span>
          </button>
        </div>

        {error && (
          <div className="bg-red-900 border border-red-700 text-red-200 px-6 py-4 rounded-lg mb-6">
            {error}
          </div>
        )}

        <div className="bg-gray-800 rounded-2xl overflow-hidden mb-6">
          <div className="p-6 border-b border-gray-700 flex items-center justify-between">
            <div>
              <h1 className="text-3xl font-bold text-white mb-2">Emergency Case Details</h1>
              <p className="text-gray-400">Case ID: {caseData.id}</p>
            </div>
            <span className={`px-6 py-3 rounded-full text-lg font-bold ${
              caseData.status === 'Pending' 
                ? 'bg-red-900 text-red-200 animate-pulse' 
                : 'bg-green-900 text-green-200'
            }`}>
              {caseData.status}
            </span>
          </div>

          <div className="p-6">
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div>
                <h3 className="text-xl font-semibold text-white mb-4">Video Recording</h3>
                {caseData.videoUrl ? (
                  <div className="bg-gray-900 rounded-xl overflow-hidden">
                    <video 
                      ref={videoRef}
                      src={getMediaUrl(caseData.videoUrl)}
                      controls
                      className="w-full"
                      onError={handleVideoError}
                    >
                      Your browser does not support video playback.
                    </video>
                    {caseData.videoSha256 && (
                      <div className="mt-3 bg-gray-800 rounded-lg p-3">
                        <p className="text-xs text-gray-400 mb-1">SHA-256 Integrity Hash (Video)</p>
                        <div className="flex items-center gap-2">
                          <code className="text-emerald-400 text-xs break-all font-mono">{caseData.videoSha256}</code>
                          <button
                            onClick={() => navigator.clipboard.writeText(caseData.videoSha256)}
                            className="text-xs text-blue-400 hover:text-blue-300 underline whitespace-nowrap"
                          >
                            Copy
                          </button>
                        </div>
                      </div>
                    )}
                  </div>
                ) : (
                  <div className="bg-gray-900 rounded-xl p-12 text-center">
                    <svg className="w-16 h-16 text-gray-600 mx-auto mb-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z" />
                    </svg>
                    <p className="text-gray-500">No video available</p>
                  </div>
                )}
              </div>

              <div>
                <h3 className="text-xl font-semibold text-white mb-4">Audio Recording</h3>
                {caseData.audioUrl ? (
                  <div className="bg-gray-900 rounded-xl p-6">
                    <audio 
                      ref={audioRef}
                      src={getMediaUrl(caseData.audioUrl)}
                      controls
                      className="w-full"
                      onError={handleAudioError}
                    >
                      Your browser does not support audio playback.
                    </audio>
                    {caseData.audioSha256 && (
                      <div className="mt-3 bg-gray-800 rounded-lg p-3">
                        <p className="text-xs text-gray-400 mb-1">SHA-256 Integrity Hash (Audio)</p>
                        <div className="flex items-center gap-2">
                          <code className="text-emerald-400 text-xs break-all font-mono">{caseData.audioSha256}</code>
                          <button
                            onClick={() => navigator.clipboard.writeText(caseData.audioSha256)}
                            className="text-xs text-blue-400 hover:text-blue-300 underline whitespace-nowrap"
                          >
                            Copy
                          </button>
                        </div>
                      </div>
                    )}
                  </div>
                ) : (
                  <div className="bg-gray-900 rounded-xl p-12 text-center">
                    <svg className="w-16 h-16 text-gray-600 mx-auto mb-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z" />
                    </svg>
                    <p className="text-gray-500">No audio available</p>
                  </div>
                )}
              </div>
            </div>
          </div>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div className="bg-gray-800 rounded-xl p-6">
            <h3 className="text-xl font-semibold text-white mb-4">Location</h3>
            {caseData.locationLink ? (
              <div className="space-y-3">
                <MapView
                  markers={(() => {
                    const ms = [{
                      lat: caseData.latitude,
                      lng: caseData.longitude,
                      popupHtml: `<b>${caseData.status || 'Emergency'} Case</b><br/>From: ${caseData.userEmail || 'Unknown'}<br/><a href="${caseData.locationLink}" target="_blank" rel="noopener noreferrer" style="color:#60a5fa">View Location</a>`,
                    }];
                    if (caseData.nearestPoliceStationLat && caseData.nearestPoliceStationLng) {
                      ms.push({
                        lat: caseData.nearestPoliceStationLat,
                        lng: caseData.nearestPoliceStationLng,
                        icon: policeStationIcon,
                        popupHtml: `<b>Nearest Police Station</b><br/>${caseData.nearestPoliceStationName || 'Police station'}${caseData.nearestPoliceStationAddress ? '<br/>' + caseData.nearestPoliceStationAddress : ''}${caseData.nearestPoliceStationDistanceM ? '<br/>' + (caseData.nearestPoliceStationDistanceM >= 1000 ? (caseData.nearestPoliceStationDistanceM/1000).toFixed(1) + ' km away' : caseData.nearestPoliceStationDistanceM + ' m away') : ''}`,
                      });
                    }
                    return ms;
                  })()}
                  height="h-64"
                  emptyText="No location data available"
                />
                <a 
                  href={caseData.locationLink}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="inline-flex items-center space-x-2 bg-blue-600 hover:bg-blue-700 text-white px-6 py-3 rounded-lg transition-colors"
                >
                  <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M17.657 16.657L13.414 20.9a1.998 1.998 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z" />
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 11a3 3 0 11-6 0 3 3 0 016 0z" />
                  </svg>
                  <span>Open in Google Maps</span>
                </a>
                <p className="text-gray-400 text-sm break-all">
                  {caseData.locationLink}
                </p>
                <div className="pt-2 border-t border-gray-700">
                  <p className="text-gray-400 text-sm mb-2">Share this emergency via WhatsApp:</p>
                  <div className="flex gap-2">
                    <input
                      type="tel"
                      value={phone}
                      onChange={(e) => setPhone(e.target.value)}
                      placeholder="Phone number (e.g. +919876543210)"
                      className="flex-1 bg-gray-700 text-white placeholder-gray-500 px-3 py-2 rounded-lg text-sm outline-none focus:ring-2 focus:ring-emerald-500"
                    />
                    <a
                      href={buildWhatsAppLink({
                        phone,
                        latitude: caseData.latitude,
                        longitude: caseData.longitude,
                        caseId: caseData.id,
                        timestamp: caseData.timestamp,
                      }) || '#'}
                      onClick={(e) => {
                        if (!buildWhatsAppLink({
                          phone,
                          latitude: caseData.latitude,
                          longitude: caseData.longitude,
                          caseId: caseData.id,
                          timestamp: caseData.timestamp,
                        })) {
                          e.preventDefault();
                          alert('Enter a valid phone number and ensure location coordinates are present.');
                        }
                      }}
                      target="_blank"
                      rel="noopener noreferrer"
                      className={`inline-flex items-center space-x-2 px-4 py-2 rounded-lg text-sm font-medium transition-colors ${buildWhatsAppLink({
                        phone,
                        latitude: caseData.latitude,
                        longitude: caseData.longitude,
                        caseId: caseData.id,
                        timestamp: caseData.timestamp,
                      }) ? 'bg-emerald-600 hover:bg-emerald-700 text-white' : 'bg-gray-700 text-gray-400 cursor-not-allowed'}`}
                    >
                      <svg className="w-5 h-5" fill="currentColor" viewBox="0 0 24 24">
                        <path d="M17.472 14.382c-.297-.149-1.758-.867-2.03-.967-.273-.099-.471-.148-.67.15-.197.297-.767.966-.94 1.164-.173.199-.347.223-.644.075-.297-.15-1.255-.463-2.39-1.475-.883-.788-1.48-1.761-1.653-2.059-.173-.297-.018-.458.13-.606.134-.133.298-.347.446-.52.149-.174.198-.298.298-.497.099-.198.05-.371-.025-.52-.075-.149-.669-1.612-.916-2.207-.242-.579-.487-.5-.669-.51-.173-.008-.371-.01-.57-.01-.198 0-.52.074-.792.372-.272.297-1.04 1.016-1.04 2.479 0 1.462 1.065 2.875 1.213 3.074.149.198 2.096 3.2 5.077 4.487.709.306 1.262.489 1.694.625.712.227 1.36.195 1.871.118.571-.085 1.758-.719 2.006-1.413.248-.694.248-1.289.173-1.413-.074-.124-.272-.198-.57-.347m-5.421 7.403h-.004a9.87 9.87 0 01-5.031-1.378l-.361-.214-3.741.982.998-3.648-.235-.374a9.86 9.86 0 01-1.51-5.26c.001-5.45 4.436-9.884 9.888-9.884 2.64 0 5.122 1.03 6.988 2.898a9.825 9.825 0 012.893 6.994c-.003 5.45-4.437 9.884-9.885 9.884m8.413-18.297A11.815 11.815 0 0012.05 0C5.495 0 .16 5.335.157 11.892c0 2.096.547 4.142 1.588 5.945L.057 24l6.305-1.654a11.882 11.882 0 005.683 1.448h.005c6.554 0 11.89-5.335 11.893-11.893a11.821 11.821 0 00-3.48-8.413z" />
                      </svg>
                      <span>WhatsApp Share</span>
                    </a>
                  </div>
                  {caseData.nearestPoliceStationName && (
                    <div className="mt-4 pt-3 border-t border-gray-700">
                      <p className="text-sm font-semibold text-blue-400 mb-1">Nearest Police Station (Tamil Nadu)</p>
                      <p className="text-white text-sm">{caseData.nearestPoliceStationName}</p>
                      {caseData.nearestPoliceStationAddress && <p className="text-gray-400 text-xs mt-1">{caseData.nearestPoliceStationAddress}</p>}
                      <p className="text-gray-400 text-xs mt-1">
                        {caseData.nearestPoliceStationDistanceM != null ? (caseData.nearestPoliceStationDistanceM >= 1000 ? `${(caseData.nearestPoliceStationDistanceM/1000).toFixed(1)} km away` : `${caseData.nearestPoliceStationDistanceM} m away`) : ''}
                        {caseData.nearestPoliceStationLat && caseData.nearestPoliceStationLng ? ` \u00B7 ${caseData.nearestPoliceStationLat}, ${caseData.nearestPoliceStationLng}` : ''}
                      </p>
                    </div>
                  )}
                </div>
              </div>
            ) : (
              <p className="text-gray-500">No location data available</p>
            )}
          </div>

          <div className="bg-gray-800 rounded-xl p-6">
            <h3 className="text-xl font-semibold text-white mb-4">Case Information</h3>
            <div className="space-y-3">
              <div className="flex justify-between">
                <span className="text-gray-400">Reporter:</span>
                <span className="text-white">{caseData.userEmail || 'Unknown'}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-gray-400">Timestamp:</span>
                <span className="text-white text-sm">{formatDate(caseData.timestamp)}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-gray-400">Status:</span>
                <span className={`font-semibold ${
                  caseData.status === 'Pending' ? 'text-red-400' : 'text-green-400'
                }`}>
                  {caseData.status}
                </span>
              </div>
              {caseData.closureReason && (
                <div className="flex justify-between">
                  <span className="text-gray-400">Closure Reason:</span>
                  <span className="text-gray-200 text-sm text-right">{caseData.closureReason}</span>
                </div>
              )}
            </div>
          </div>
        </div>

        <div className="mt-6 bg-gray-800 rounded-xl p-6">
          <h3 className="text-xl font-semibold text-white mb-4">Case Timeline</h3>
          {timeline.length === 0 ? (
            <p className="text-gray-500">No timeline events yet</p>
          ) : (
            <div className="border-l border-gray-700 pl-4 space-y-4">
              {timeline.map((e, idx) => (
                <div key={idx}>
                  <p className="text-white font-medium">{e.action}</p>
                  {e.details && <p className="text-gray-400 text-sm">{e.details}</p>}
                  <p className="text-gray-500 text-xs">{formatDate(e.createdAt)}</p>
                </div>
              ))}
            </div>
          )}
        </div>

        <div className="mt-6 bg-gray-800 rounded-xl p-6">
          <h3 className="text-xl font-semibold text-white mb-4">Notes</h3>
          <textarea
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            className="w-full h-32 bg-gray-900 text-white border border-gray-700 rounded-lg p-4 focus:ring-2 focus:ring-blue-500 focus:border-transparent"
            placeholder="Add notes about this case..."
          />
          <button
            onClick={handleNotesUpdate}
            disabled={saving || notes === caseData.notes}
            className="mt-4 bg-blue-600 hover:bg-blue-700 disabled:bg-gray-600 disabled:cursor-not-allowed text-white px-6 py-2 rounded-lg transition-colors"
          >
            {saving ? 'Saving...' : 'Save Notes'}
          </button>
        </div>

        {canManage && (
          <div className="mt-6 bg-gray-800 rounded-xl p-6">
            <h3 className="text-xl font-semibold text-white mb-4">Case Actions</h3>
            <div className="flex flex-wrap gap-4">
              {caseData.status === 'Pending' && (
                <button
                  onClick={() => setShowClosure(true)}
                  disabled={updating}
                  className="bg-green-600 hover:bg-green-700 disabled:bg-gray-600 text-white px-8 py-3 rounded-lg font-semibold transition-colors flex items-center space-x-2"
                >
                  <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
                  </svg>
                  <span>Mark as Resolved</span>
                </button>
              )}
              
              {caseData.status === 'Resolved' && (
                <button
                  onClick={() => handleStatusUpdate('Pending')}
                  disabled={updating}
                  className="bg-yellow-600 hover:bg-yellow-700 disabled:bg-gray-600 text-white px-8 py-3 rounded-lg font-semibold transition-colors flex items-center space-x-2"
                >
                  <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
                  </svg>
                  <span>Reopen Case</span>
                </button>
              )}

              <button
                onClick={() => {
                  const win = window.open('', '_blank');
                  win.document.write(generateReportHTML());
                  win.document.close();
                  win.print();
                }}
                className="bg-gray-600 hover:bg-gray-700 text-white px-8 py-3 rounded-lg font-semibold transition-colors flex items-center space-x-2"
              >
                <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M17 17h2a2 2 0 002-2v-4a2 2 0 00-2-2H5a2 2 0 00-2 2v4a2 2 0 002 2h2m2 4h6a2 2 0 002-2v-4a2 2 0 00-2-2H9a2 2 0 00-2 2v4a2 2 0 002 2zm8-12V5a2 2 0 00-2-2H9a2 2 0 00-2 2v4h10z" />
                </svg>
                <span>Export PDF Report</span>
              </button>
            </div>
          </div>
        )}

        {showClosure && (
          <div
            className="fixed inset-0 z-50 bg-black/60 p-4 flex items-center justify-center"
            onClick={() => setShowClosure(false)}
          >
            <div
              className="bg-gray-800 border border-gray-700 rounded-xl p-5 max-w-sm w-full"
              onClick={(e) => e.stopPropagation()}
            >
              <h3 className="text-xl font-semibold text-white mb-1">Resolve Case</h3>
              <p className="text-gray-400 text-sm mb-4">Select a closure reason</p>
              <select
                value={closureReason}
                onChange={(e) => setClosureReason(e.target.value)}
                className="w-full bg-gray-700 text-white px-3 py-2 rounded-lg mb-3 outline-none focus:ring-2 focus:ring-green-500"
              >
                <option value="">Select reason...</option>
                {CLOSURE_REASONS.map((r) => (
                  <option key={r} value={r}>{r}</option>
                ))}
              </select>
              {closureReason === 'Other' && (
                <input
                  type="text"
                  value={customReason}
                  onChange={(e) => setCustomReason(e.target.value)}
                  placeholder="Describe the reason"
                  className="w-full bg-gray-700 text-white placeholder-gray-500 px-3 py-2 rounded-lg mb-3 outline-none focus:ring-2 focus:ring-green-500"
                />
              )}
              <div className="flex gap-2 mt-4">
                <button
                  onClick={confirmResolve}
                  disabled={updating}
                  className="flex-1 bg-green-600 hover:bg-green-700 disabled:bg-gray-600 text-white px-4 py-2 rounded-lg font-semibold transition-colors"
                >
                  Confirm Resolve
                </button>
                <button
                  onClick={() => setShowClosure(false)}
                  className="flex-1 bg-gray-600 hover:bg-gray-700 text-white px-4 py-2 rounded-lg font-semibold transition-colors"
                >
                  Cancel
                </button>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
};

export default CaseDetails;
