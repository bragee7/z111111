import { useEffect, useRef, useState } from 'react';
import L from 'leaflet';
import 'leaflet/dist/leaflet.css';

const isValidLat = (v) => Number.isFinite(Number(v)) && Math.abs(Number(v)) <= 90;
const isValidLng = (v) => Number.isFinite(Number(v)) && Math.abs(Number(v)) <= 180;

const defaultIcon = L.icon({
  iconUrl:
    'data:image/svg+xml;charset=UTF-8,' +
    encodeURIComponent(
      `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="#DC2626" stroke="#fff" stroke-width="1.5"><path stroke-linecap="round" stroke-linejoin="round" d="M15 10.5a3 3 0 11-6 0 3 3 0 016 0z"/><path stroke-linecap="round" stroke-linejoin="round" d="M19.5 10.5c0 7.142-7.5 11.25-7.5 11.25S4.5 17.642 4.5 10.5a7.5 7.5 0 1115 0z"/></svg>`
    ),
  iconSize: [30, 30],
  iconAnchor: [15, 30],
  popupAnchor: [0, -28],
});

export const policeStationIcon = L.icon({
  iconUrl:
    'data:image/svg+xml;charset=UTF-8,' +
    encodeURIComponent(
      `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="#2563EB" stroke="#fff" stroke-width="1.5"><path d="M3 21V4a3 3 0 013-3h8a3 3 0 013 3v17" fill="#2563EB"/><path d="M9 9h6M9 13h6M9 17h6" stroke="#fff" stroke-width="1.2"/><circle cx="15" cy="7.5" r="1" fill="#fff"/></svg>`
    ),
  iconSize: [30, 30],
  iconAnchor: [15, 30],
  popupAnchor: [0, -28],
});

const MapView = ({
  markers = [],
  height = 'h-72',
  emptyText = 'No location data available',
}) => {
  const containerRef = useRef(null);
  const mapRef = useRef(null);
  const markersRef = useRef([]);
  const [mapState, setMapState] = useState({
    hasValid: false,
    empty: markers.length === 0,
    error: false,
  });

  useEffect(() => {
    if (!containerRef.current || mapRef.current) return;
    try {
      mapRef.current = L.map(containerRef.current, {
        center: [20, 0],
        zoom: 2,
        scrollWheelZoom: false,
      });
      L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
        maxZoom: 19,
        attribution: '&copy; OpenStreetMap contributors',
      }).addTo(mapRef.current);
    } catch (e) {
      setMapState((s) => ({ ...s, error: true }));
      return;
    }
    return () => {
      if (mapRef.current) {
        mapRef.current.remove();
        mapRef.current = null;
      }
    };
  }, []);

  useEffect(() => {
    const valid = (markers || []).filter(
      (m) => isValidLat(m.lat) && isValidLng(m.lng)
    );
    const hasValid = valid.length > 0;
    setMapState((s) => ({
      ...s,
      hasValid,
      empty: !hasValid,
      error: false,
    }));

    const map = mapRef.current;
    if (!map) return;

    markersRef.current.forEach((m) => m.remove());
    markersRef.current = [];

    valid.forEach((m) => {
      const marker = L.marker([Number(m.lat), Number(m.lng)], {
        icon: m.icon || defaultIcon,
      });
      if (m.popupHtml) marker.bindPopup(m.popupHtml);
      marker.addTo(map);
      markersRef.current.push(marker);
    });

    if (hasValid) {
      const bounds = L.latLngBounds(valid.map((m) => [Number(m.lat), Number(m.lng)]));
      map.fitBounds(bounds, { padding: [40, 40], maxZoom: 15 });
    }
  }, [markers]);

  if (mapState.error) {
    return (
      <div className={`${height} bg-gray-800 rounded-lg flex items-center justify-center`}>
        <p className="text-gray-400 text-sm">Map failed to load.</p>
      </div>
    );
  }

  if (mapState.empty && !mapRef.current) {
    return (
      <div className={`${height} bg-gray-800 rounded-lg flex items-center justify-center`}>
        <p className="text-gray-400 text-sm">{emptyText}</p>
      </div>
    );
  }

  return <div ref={containerRef} className={`${height} w-full rounded-lg z-0`} />;
};

export default MapView;