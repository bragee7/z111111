import { useCallback, useEffect, useRef, useState } from 'react';

/**
 * Shared emergency alarm for the police/admin dashboards.
 *
 * Browsers block audio until the user interacts with the page, so we create
 * and resume a single AudioContext on the first pointer/key event. The same
 * context is then reused for every alarm; creating a new context per alert
 * eventually hits the browser's context limit and silently stops working.
 */
export const useEmergencyAlert = (durationMs = 10000) => {
  const [alertActive, setAlertActive] = useState(false);
  const [audioReady, setAudioReady] = useState(false);
  const ctxRef = useRef(null);
  const timerRef = useRef(null);

  const ensureAudio = useCallback(() => {
    try {
      const Ctx = window.AudioContext || window.webkitAudioContext;
      if (!Ctx) return null;
      if (!ctxRef.current) ctxRef.current = new Ctx();
      if (ctxRef.current.state === 'suspended') {
        ctxRef.current.resume().catch(() => {});
      }
      setAudioReady(true);
      return ctxRef.current;
    } catch {
      return null;
    }
  }, []);

  useEffect(() => {
    const unlock = () => ensureAudio();
    window.addEventListener('pointerdown', unlock, { once: true });
    window.addEventListener('keydown', unlock, { once: true });
    return () => {
      window.removeEventListener('pointerdown', unlock);
      window.removeEventListener('keydown', unlock);
      if (timerRef.current) clearTimeout(timerRef.current);
      if (ctxRef.current) {
        try { ctxRef.current.close(); } catch { /* already closed */ }
        ctxRef.current = null;
      }
    };
  }, [ensureAudio]);

  const playAlarm = useCallback(() => {
    const ctx = ensureAudio();
    if (!ctx) return;
    try {
      const start = ctx.currentTime;
      const gain = ctx.createGain();
      gain.gain.setValueAtTime(0.0001, start);
      gain.gain.exponentialRampToValueAtTime(0.35, start + 0.02);
      gain.gain.exponentialRampToValueAtTime(0.0001, start + 0.95);
      gain.connect(ctx.destination);

      [0, 0.28, 0.56].forEach((offset, index) => {
        const osc = ctx.createOscillator();
        osc.type = 'square';
        const high = index === 2;
        osc.frequency.setValueAtTime(high ? 1000 : 800, start + offset);
        osc.frequency.setValueAtTime(high ? 1300 : 600, start + offset + 0.13);
        osc.connect(gain);
        osc.start(start + offset);
        osc.stop(start + offset + 0.24);
      });

      if (ctx.state === 'suspended') ctx.resume().catch(() => {});
    } catch {
      // Audio is best-effort; the visual banner still fires.
    }
  }, [ensureAudio]);

  const triggerAlert = useCallback(() => {
    setAlertActive(true);
    playAlarm();
    if (timerRef.current) clearTimeout(timerRef.current);
    timerRef.current = setTimeout(() => setAlertActive(false), durationMs);
  }, [durationMs, playAlarm]);

  const dismissAlert = useCallback(() => {
    setAlertActive(false);
    if (timerRef.current) clearTimeout(timerRef.current);
  }, []);

  return { alertActive, audioReady, triggerAlert, dismissAlert, ensureAudio };
};
