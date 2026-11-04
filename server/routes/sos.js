const express = require('express');
const multer = require('multer');
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { v4: uuidv4 } = require('uuid');
const { authMiddleware } = require('../middleware/auth');
const { query, auditLog } = require('../db');
const storage = require('../storage');
const { emitNewCase, emitCaseUpdated } = require('../socket');
const emailService = require('../services/email');
const { findNearestPoliceStation } = require('../services/policeStationService');

const router = express.Router();

const upload = multer({
  storage: multer.diskStorage({
    destination: (req, file, cb) => {
      const dir = path.join(os.tmpdir(), 'zelda-uploads');
      fs.mkdirSync(dir, { recursive: true });
      cb(null, dir);
    },
    filename: (req, file, cb) => {
      cb(null, `${uuidv4()}-${Date.now()}`);
    }
  }),
  limits: { fileSize: 200 * 1024 * 1024 },
  fileFilter: (req, file, cb) => {
    const allowedMime = /^(video|audio)\//;
    if (allowedMime.test(file.mimetype)) {
      cb(null, true);
    } else {
      const err = new Error('Only video and audio files are allowed');
      err.status = 400;
      cb(err);
    }
  }
});

const handleMulterError = (err, req, res, next) => {
  if (err instanceof multer.MulterError) {
    return res.status(400).json({ error: `Upload error: ${err.message}` });
  }
  if (err) {
    // fileFilter rejections (e.g. non-video/audio) carry status 400; unknown upload errors stay 500
    const status = err.status === 400 || err.statusCode === 400 || err.message === 'Only video and audio files are allowed' ? 400 : 500;
    return res.status(status).json({ error: `Upload error: ${err.message}` });
  }
  next();
};

// The browser/phone may declare a generic or wrong content type (Dio defaults
// to application/octet-stream), so prefer a real, allow-listed extension from
// the original filename before falling back to the MIME family. Without this a
// genuine .mp4 recording was stored on B2 as ".webm".
const SAFE_EXTENSIONS = new Set([
  '.mp4', '.mov', '.webm', '.mkv', '.3gp', '.m4v', '.m4a', '.aac', '.mp3', '.wav', '.ogg', '.opus',
]);

const extname = (mimetype = '', originalName = '') => {
  const fromName = path.extname(originalName || '').toLowerCase();
  if (SAFE_EXTENSIONS.has(fromName)) return fromName;
  if (mimetype.startsWith('video/')) {
    if (mimetype.includes('mp4')) return '.mp4';
    if (mimetype.includes('quicktime')) return '.mov';
    return '.webm';
  }
  if (mimetype.startsWith('audio/')) {
    if (mimetype.includes('mpeg')) return '.mp3';
    if (mimetype.includes('mp4') || mimetype.includes('m4a')) return '.m4a';
    return '.webm';
  }
  return '.bin';
};

// Content-Type and filename can both lie (older builds always uploaded a
// "*.webm" name for MP4 bytes). Sniff the container magic instead so the
// stored object keeps the extension a reviewer's player expects.
const sniffExtension = (filePath) => {
  try {
    const fd = fs.openSync(filePath, 'r');
    const header = Buffer.alloc(12);
    const read = fs.readSync(fd, header, 0, header.length, 0);
    fs.closeSync(fd);
    if (read >= 12 && header.toString('ascii', 4, 8) === 'ftyp') return '.mp4';
    if (read >= 4 && header[0] === 0x1a && header[1] === 0x45 && header[2] === 0xdf && header[3] === 0xa3) return '.webm';
    if (read >= 12 && header.toString('ascii', 0, 4) === 'RIFF') {
      return header.toString('ascii', 8, 12) === 'WAVE' ? '.wav' : '.avi';
    }
    if (read >= 3 && header.toString('ascii', 0, 3) === 'ID3') return '.mp3';
  } catch (_) {}
  return '';
};

const uploadMedia = async (file, { sniff = false } = {}) => {
  if (!file) return null;

  const extension = (sniff ? sniffExtension(file.path) : '') ||
    extname(file.mimetype, file.originalname);
  const fileName = `${uuidv4()}${extension}`;

  let sha256 = null;
  try {
    const buffer = fs.readFileSync(file.path);
    sha256 = crypto.createHash('sha256').update(buffer).digest('hex');
  } catch (_) {}

  if (!storage.isConfigured()) {
    try { fs.unlink(file.path, () => {}); } catch (_) {}
    return null;
  }

  // Fail-OPEN: a storage blip must never lose a victim alert - log + return null so the SOS case is still created.
  try {
    const publicUrl = await storage.upload(file, fileName);

    try {
      fs.unlink(file.path, () => {});
    } catch (_) {}

    if (!publicUrl) {
      console.error('[sos] media upload failed (fail-open, case still created)');
      return null;
    }

    return { publicUrl, sha256 };
  } catch (err) {
    console.error('[sos] media upload threw (fail-open, case still created):', err && err.message ? err.message : err);
    try {
      fs.unlink(file.path, () => {});
    } catch (_) {}
    return null;
  }
};
const notifySOS = async (caseForEmail, videoUrl, audioUrl, userId) => {
  try {
    const emailResult = await emailService.sendSOSAlert(caseForEmail, videoUrl, audioUrl);

    if (emailResult.success) {
      await auditLog(userId, caseForEmail.id, 'EMAIL_SENT', `SOS alert email sent to police: ${emailResult.messageId}`);
    } else {
      await auditLog(userId, caseForEmail.id, 'EMAIL_FAILED', `Failed to send SOS email: ${emailResult.error}`);
    }

    const contacts = await query(
      'SELECT * FROM contacts WHERE user_id = $1',
      [userId]
    );

    for (const contact of contacts) {
      if (contact.email) {
        const contactResult = await emailService.sendContactSOSAlert(caseForEmail, contact);
        if (contactResult.success) {
          await auditLog(userId, caseForEmail.id, 'CONTACT_EMAIL_SENT', `SOS alert sent to contact: ${contact.name} (${contact.email})`);
        } else {
          await auditLog(userId, caseForEmail.id, 'CONTACT_EMAIL_FAILED', `Failed to send SOS to contact: ${contact.name} - ${contactResult.error}`);
        }
      }
    }
  } catch (error) {
    console.error('SOS notification error:', error);
  }
};

const asText = (value) => (value === undefined || value === null ? '' : String(value).trim());
const truncate = (value, max) => asText(value).slice(0, max);
const parseDate = (value) => {
  if (!value) return null;
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
};
const parseBool = (value, fallback = false) => {
  if (typeof value === 'boolean') return value;
  const normalized = asText(value).toLowerCase();
  if (['1', 'true', 'yes', 'on'].includes(normalized)) return true;
  if (['0', 'false', 'no', 'off'].includes(normalized)) return false;
  return fallback;
};
const cleanupFile = (file) => {
  if (!file || !file.path) return;
  try { fs.unlink(file.path, () => {}); } catch (_) {}
};
const cleanupRequestFiles = (req) => {
  for (const list of Object.values(req.files || {})) {
    for (const file of list || []) cleanupFile(file);
  }
};
const uploadEvidenceIfMissing = async (file, existingRef, existingSha, { sniff = false } = {}) => {
  if (!file) {
    return { ref: existingRef || null, sha: existingSha || null, attempted: false };
  }
  // Evidence is immutable once accepted. A retry must never overwrite the
  // original recording with a different file.
  if (existingRef) {
    cleanupFile(file);
    return { ref: existingRef, sha: existingSha || null, attempted: false };
  }
  const media = await uploadMedia(file, { sniff });
  return {
    ref: media ? media.publicUrl : null,
    sha: media ? media.sha256 : null,
    attempted: true,
  };
};
const resolveEvidenceStatus = ({
  evidenceExpected,
  videoExpected,
  audioExpected,
  video,
  audio,
}) => {
  const attempted = video.attempted || audio.attempted;
  const uploaded = !!video.ref || !!audio.ref;
  const failed = (video.attempted && !video.ref) || (audio.attempted && !audio.ref);
  const expectedMissing =
    (videoExpected && !video.ref) || (audioExpected && !audio.ref);

  if (failed && uploaded) return 'partial';
  if (failed) return 'failed';
  // A missing expected track is not "complete" just because the other track
  // uploaded successfully. This is what tells the phone to retry evidence
  // instead of falsely reporting a fully-synced SOS.
  if (expectedMissing) return uploaded ? 'partial' : 'missing';
  if (uploaded) return 'complete';
  return evidenceExpected ? 'missing' : 'none';
};
const isEvidenceFinal = (status) => status === 'complete' || status === 'none';

const persistEvidence = async (
  existingCase,
  videoFile,
  audioFile,
  evidenceExpected,
  videoExpected,
  audioExpected
) => {
  const video = await uploadEvidenceIfMissing(
    videoFile,
    existingCase.video_url,
    existingCase.video_sha256,
    { sniff: true }
  );
  const audio = await uploadEvidenceIfMissing(
    audioFile,
    existingCase.audio_url,
    existingCase.audio_sha256
  );
  const evidenceStatus = resolveEvidenceStatus({
    evidenceExpected,
    videoExpected,
    audioExpected,
    video,
    audio,
  });
  const syncedAt = isEvidenceFinal(evidenceStatus)
    ? (existingCase.synced_at || new Date())
    : null;
  const rows = await query(
    `UPDATE sos_cases
        SET video_url = $1, audio_url = $2, video_sha256 = $3, audio_sha256 = $4,
            evidence_status = $5, synced_at = $6, updated_at = now()
      WHERE id = $7
      RETURNING *`,
    [
      video.ref,
      audio.ref,
      video.sha,
      audio.sha,
      evidenceStatus,
      syncedAt,
      existingCase.id,
    ]
  );
  return rows[0];
};

const findExistingByClientReference = async (userId, clientReference) => {
  try {
    return await query(
      'SELECT * FROM sos_cases WHERE user_id = $1 AND client_reference = $2 LIMIT 1',
      [userId, clientReference]
    );
  } catch (error) {
    // Deploy-before-migration: idempotency is unavailable until the migration
    // runs, but an emergency must still be accepted.
    if (error.code === '42703') {
      console.warn('[sos] client_reference column missing; idempotency disabled until migration runs');
      return [];
    }
    throw error;
  }
};

const persistEvidenceLegacy = async (existingCase, videoFile, audioFile) => {
  const video = await uploadEvidenceIfMissing(
    videoFile,
    existingCase.video_url,
    existingCase.video_sha256,
    { sniff: true }
  );
  const audio = await uploadEvidenceIfMissing(
    audioFile,
    existingCase.audio_url,
    existingCase.audio_sha256
  );
  const rows = await query(
    `UPDATE sos_cases
        SET video_url = $1, audio_url = $2, video_sha256 = $3, audio_sha256 = $4,
            updated_at = now()
      WHERE id = $5
      RETURNING *`,
    [video.ref, audio.ref, video.sha, audio.sha, existingCase.id]
  );
  return rows[0];
};

const respondWithExistingCase = async (
  existingCase,
  req,
  evidenceExpected,
  videoExpected,
  audioExpected,
  videoFile,
  audioFile
) => {
  const updated = await persistEvidence(
    existingCase,
    videoFile,
    audioFile,
    evidenceExpected,
    videoExpected,
    audioExpected
  );
  const mapped = await mapCase(updated);
  emitCaseUpdated(mapped);
  await auditLog(
    req.user.userId,
    updated.id,
    'SOS_IDEMPOTENT_REPLAY',
    `Duplicate SOS request for client reference ${existingCase.client_reference || '(none)'}; returned existing case`
  );
  return {
    message: 'SOS case already exists',
    duplicate: true,
    case: mapped,
  };
};

router.post('/', authMiddleware, (req, res, next) => {
  upload.fields([
    { name: 'video', maxCount: 1 },
    { name: 'audio', maxCount: 1 }
  ])(req, res, (err) => {
    if (err) return handleMulterError(err, req, res, next);
    next();
  });
}, async (req, res) => {
  try {
    if (!req.user) {
      return res.status(401).json({ error: 'User not authenticated' });
    }

    if (req.user.role === 'police' || req.user.role === 'admin') {
      return res.status(403).json({ error: 'Police and admin accounts cannot create SOS cases' });
    }

    const {
      locationLink,
      latitude,
      longitude,
      notes,
    } = req.body;

    const latValue = asText(latitude) || null;
    const lngValue = asText(longitude) || null;
    const locValue = asText(locationLink) || null;
    const clientReference = truncate(req.body.clientReference, 120) || null;
    const deviceId = truncate(req.body.deviceId, 200) || null;
    const appVersion = truncate(req.body.appVersion, 80) || null;
    const triggerType = truncate(req.body.triggerType, 40) || 'manual';

    if (clientReference && !/^[A-Za-z0-9][A-Za-z0-9._:-]{7,119}$/.test(clientReference)) {
      return res.status(400).json({ error: 'Invalid clientReference' });
    }

    const videoFile = req.files?.video?.[0];
    const audioFile = req.files?.audio?.[0];
    const hasUploadedFile = !!(videoFile || audioFile);
    const evidenceExpected = req.body.evidenceExpected !== undefined
      ? parseBool(req.body.evidenceExpected, hasUploadedFile)
      : hasUploadedFile;
    // New clients say which tracks they intended to record. Without this a
    // video whose upload failed could look "complete" because audio uploaded.
    // Legacy clients fall back to the files actually present.
    const videoExpected = req.body.videoExpected !== undefined
      ? parseBool(req.body.videoExpected, !!videoFile)
      : !!videoFile;
    const audioExpected = req.body.audioExpected !== undefined
      ? parseBool(req.body.audioExpected, !!audioFile)
      : !!audioFile;

    const receivedAt = new Date();
    const capturedAt = parseDate(req.body.capturedAt) || receivedAt;
    const skewSeconds = Math.round((capturedAt.getTime() - receivedAt.getTime()) / 1000);
    // A negative offset is the normal shape of an offline queue: the phone
    // captured the alert, then delivered it minutes/hours later. Only a
    // capturedAt in the FUTURE proves the device clock is wrong.
    const clockSkewSeconds = skewSeconds > 300 ? skewSeconds : null;
    const requestedSource = asText(req.body.syncSource);
    const sendDelayMs = receivedAt.getTime() - capturedAt.getTime();
    // Never trust "online" for a case that clearly arrived late. This keeps
    // the dashboard honest even if the process died before the phone could
    // update its local sync source.
    const syncSource =
      requestedSource === 'offline_sync' || sendDelayMs > 60_000
        ? 'offline_sync'
        : 'online';
    const testRequested =
      req.get('x-zelda-test') === '1' || parseBool(req.body.isTest, false);
    const isTest =
      testRequested &&
      process.env.ALLOW_TEST_SOS === 'true' &&
      process.env.NODE_ENV !== 'production';

    // Idempotency: the phone retries with the same stable reference. Find the
    // case before touching media storage so a retry can never create a second
    // emergency record.
    if (clientReference) {
      const existingRows = await findExistingByClientReference(
        req.user.userId,
        clientReference
      );
      if (existingRows.length > 0) {
        const payload = await respondWithExistingCase(
          existingRows[0],
          req,
          evidenceExpected,
          videoExpected,
          audioExpected,
          videoFile,
          audioFile
        );
        return res.status(200).json(payload);
      }
    }

    // Tamil Nadu: resolve nearest police station (backend authoritative, fail-open — SOS never blocked)
    let station = null;
    if (latValue != null && lngValue != null) {
      const nLat = Number(latValue);
      const nLng = Number(lngValue);
      if (Number.isFinite(nLat) && Number.isFinite(nLng)) {
        try {
          station = await findNearestPoliceStation(nLat, nLng);
        } catch (e) {
          console.warn('[sos] station lookup threw:', e.message);
          station = null;
        }
      }
    }

    const initialEvidenceStatus = evidenceExpected ? 'pending' : 'none';
    const initialSyncedAt = evidenceExpected ? null : receivedAt;

    const insertValues = [
      req.user.userId,
      req.user.email,
      locValue,
      latValue,
      lngValue,
      'Pending',
      notes || '',
      triggerType,
      receivedAt,
      receivedAt,
      clientReference,
      capturedAt,
      receivedAt,
      initialSyncedAt,
      syncSource,
      initialEvidenceStatus,
      deviceId,
      appVersion,
      isTest,
      clockSkewSeconds,
      station?.name ?? null,
      station?.address ?? null,
      station?.lat ?? null,
      station?.lng ?? null,
      station?.distanceM ?? null,
      station?.osmId ?? null,
      station?.osmType ?? null,
      station?.fetchedAt ?? null,
    ];
    const placeholders = insertValues.map((_, index) => `$${index + 1}`).join(', ');
    const conflictClause = clientReference
      ? 'ON CONFLICT (user_id, client_reference) WHERE client_reference IS NOT NULL DO NOTHING'
      : '';

    let insertedRows;
    let legacyInsert = false;
    try {
      insertedRows = await query(
        `INSERT INTO sos_cases (
           user_id, user_email, location_link, latitude, longitude, status, notes,
           trigger_type, created_at, updated_at, client_reference, captured_at,
           received_at, synced_at, sync_source, evidence_status, device_id,
           app_version, is_test, clock_skew_seconds,
           nearest_police_station_name, nearest_police_station_address,
           nearest_police_station_lat, nearest_police_station_lng,
           nearest_police_station_distance_m, nearest_police_station_osm_id,
           nearest_police_station_osm_type, nearest_police_station_fetched_at
         ) VALUES (${placeholders})
         ${conflictClause}
         RETURNING *`,
        insertValues
      );
    } catch (e) {
      // Deploy-before-migration safety: keep the emergency alert alive even if
      // the offline columns are not present yet. Idempotency is unavailable in
      // this degraded path; the migration must be applied immediately.
      if (e.code === '42703') {
        console.warn('[sos] offline-sync columns missing; using legacy insert:', e.message);
        legacyInsert = true;
        insertedRows = await query(
          `INSERT INTO sos_cases (user_id, user_email, location_link, latitude, longitude, status, notes, trigger_type, created_at, updated_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING *`,
          [
            req.user.userId,
            req.user.email,
            locValue,
            latValue,
            lngValue,
            'Pending',
            notes || '',
            triggerType,
            receivedAt,
            receivedAt,
          ]
        );
      } else {
        throw e;
      }
    }

    if (!insertedRows || insertedRows.length === 0) {
      // Another request won the unique-index race between our SELECT and INSERT.
      if (!clientReference) {
        throw new Error('SOS insert returned no row without a client reference');
      }
      const racedRows = await findExistingByClientReference(
        req.user.userId,
        clientReference
      );
      if (racedRows.length === 0) {
        throw new Error('SOS insert conflicted but the existing case was not found');
      }
      const payload = await respondWithExistingCase(
        racedRows[0],
        req,
        evidenceExpected,
        videoExpected,
        audioExpected,
        videoFile,
        audioFile
      );
      return res.status(200).json(payload);
    }

    const insertedCase = insertedRows[0];
    const insertId = insertedCase.id;

    await auditLog(
      req.user.userId,
      insertId,
      syncSource === 'offline_sync' ? 'SOS_CREATED_OFFLINE' : 'SOS_CREATED',
      syncSource === 'offline_sync'
        ? `Offline SOS captured at ${capturedAt.toISOString()} and received at ${receivedAt.toISOString()}`
        : `SOS alert created by user ${req.user.email}`
    );

    // Emit immediately so the dashboard receives the emergency even while a
    // large video is still uploading.
    emitNewCase(await mapCase(insertedCase));

    const completedCase = legacyInsert
      ? await persistEvidenceLegacy(insertedCase, videoFile, audioFile)
      : await persistEvidence(
          insertedCase,
          videoFile,
          audioFile,
          evidenceExpected,
          videoExpected,
          audioExpected
        );
    const mappedCase = await mapCase(completedCase);

    emitCaseUpdated(mappedCase);

    // Notify on the first insert only. Even an offline case whose evidence
    // upload failed must reach the police email channel; the dashboard still
    // shows evidenceStatus=failed so nobody assumes the video is available.
    if (!isTest) {
      const [videoUrl, audioUrl] = await Promise.all([
        storage.resolveUrl(completedCase.video_url, 7 * 24 * 60 * 60),
        storage.resolveUrl(completedCase.audio_url, 7 * 24 * 60 * 60),
      ]);
      const caseForEmail = {
        id: insertId,
        user_id: req.user.userId,
        user_email: req.user.email,
        location_link: locValue,
        status: 'Pending',
        notes: notes || '',
        created_at: receivedAt,
        captured_at: capturedAt,
        received_at: receivedAt,
        sync_source: syncSource,
      };
      // Fire-and-forget: notification failures must not fail the SOS response.
      notifySOS(caseForEmail, videoUrl, audioUrl, req.user.userId);
    }

    return res.status(201).json({
      message: 'SOS case created successfully',
      duplicate: false,
      case: mappedCase,
    });
  } catch (error) {
    console.error('Create case error:', error);
    return res.status(500).json({ error: 'Error creating SOS case' });
  } finally {
    // uploadMedia deletes successful temp files; this covers validation errors
    // and duplicate requests that never reached the uploader.
    cleanupRequestFiles(req);
  }
});

const mapCase = async (c) => ({
  id: c.id,
  userId: c.user_id,
  userEmail: c.user_email,
  locationLink: c.location_link,
  latitude: c.latitude,
  longitude: c.longitude,
  status: c.status,
  notes: c.notes,
  videoUrl: await storage.resolveUrl(c.video_url),
  audioUrl: await storage.resolveUrl(c.audio_url),
  videoSha256: c.video_sha256,
  audioSha256: c.audio_sha256,
  triggerType: c.trigger_type,
  // The incident time is preserved across an offline sync. `timestamp` keeps
  // the old contract working but now prefers the captured time.
  capturedAt: c.captured_at || c.created_at,
  receivedAt: c.received_at || c.created_at,
  syncedAt: c.synced_at || null,
  syncSource: c.sync_source || 'online',
  evidenceStatus: c.evidence_status || (c.video_url || c.audio_url ? 'complete' : 'none'),
  deviceId: c.device_id || null,
  appVersion: c.app_version || null,
  isTest: c.is_test === true,
  clockSkewSeconds: c.clock_skew_seconds ?? null,
  timestamp: c.captured_at || c.created_at,
  createdAt: c.created_at,
  updatedAt: c.updated_at,
  closureReason: c.closure_reason,
  nearestPoliceStationName: c.nearest_police_station_name ?? null,
  nearestPoliceStationAddress: c.nearest_police_station_address ?? null,
  nearestPoliceStationLat: c.nearest_police_station_lat ?? null,
  nearestPoliceStationLng: c.nearest_police_station_lng ?? null,
  nearestPoliceStationDistanceM: c.nearest_police_station_distance_m ?? null,
  nearestPoliceStationOsmId: c.nearest_police_station_osm_id ?? null,
  nearestPoliceStationOsmType: c.nearest_police_station_osm_type ?? null,
  nearestPoliceStationFetchedAt: c.nearest_police_station_fetched_at ?? null,
});

router.get('/', authMiddleware, async (req, res) => {
  try {
    let cases;

    if (req.user.role === 'police' || req.user.role === 'admin') {
      cases = await query('SELECT * FROM sos_cases ORDER BY created_at DESC');
    } else {
      cases = await query('SELECT * FROM sos_cases WHERE user_id = $1 ORDER BY created_at DESC', [req.user.userId]);
    }

    res.json({ cases: await Promise.all(cases.map(mapCase)) });
  } catch (error) {
    console.error('Get cases error:', error);
    res.status(500).json({ error: 'Error fetching cases' });
  }
});

router.get('/test-email', authMiddleware, async (req, res) => {
  try {
    const result = await emailService.sendTestEmail();
    if (result.success) {
      res.json({
        status: 'success',
        message: 'Email configuration is valid',
        config: {
          host: emailService.isEmailConfigured() ? 'configured' : 'not configured',
          policeEmail: require('../config').email.policeEmail
        }
      });
    } else {
      res.status(400).json({
        status: 'error',
        message: result.error,
        config: {
          host: 'configured but invalid',
          policeEmail: require('../config').email.policeEmail
        }
      });
    }
  } catch (error) {
    res.status(500).json({ status: 'error', message: error.message });
  }
});

router.get('/:id', authMiddleware, async (req, res) => {
  try {
    const cases = await query('SELECT * FROM sos_cases WHERE id = $1', [req.params.id]);
    const caseData = cases[0];

    if (!caseData) {
      return res.status(404).json({ error: 'Case not found' });
    }

    if (req.user.role !== 'police' && req.user.role !== 'admin' && caseData.user_id !== req.user.userId) {
      return res.status(403).json({ error: 'Access denied' });
    }

    res.json({ case: await mapCase(caseData) });
  } catch (error) {
    console.error('Get case error:', error);
    res.status(500).json({ error: 'Error fetching case' });
  }
});

router.get('/:id/timeline', authMiddleware, async (req, res) => {
  try {
    const cases = await query('SELECT * FROM sos_cases WHERE id = $1', [req.params.id]);
    const caseData = cases[0];

    if (!caseData) {
      return res.status(404).json({ error: 'Case not found' });
    }

    if (req.user.role !== 'police' && req.user.role !== 'admin' && caseData.user_id !== req.user.userId) {
      return res.status(403).json({ error: 'Access denied' });
    }

    const events = await query(
      'SELECT action, details, created_at FROM audit_log WHERE case_id = $1 ORDER BY created_at DESC',
      [req.params.id]
    );

    res.json({
      timeline: events.map((e) => ({
        action: e.action,
        details: e.details,
        createdAt: e.created_at,
      })),
    });
  } catch (error) {
    console.error('Get case timeline error:', error);
    res.status(500).json({ error: 'Error fetching case timeline' });
  }
});

router.put('/:id', authMiddleware, async (req, res) => {
  try {
    if (req.user.role !== 'police' && req.user.role !== 'admin') {
      return res.status(403).json({ error: 'Only police and admin can update case status and notes' });
    }

    const { status, notes, closureReason } = req.body;
    const updatedAt = new Date();

    const existingCases = await query('SELECT * FROM sos_cases WHERE id = $1', [req.params.id]);
    const existingCase = existingCases[0];

    if (!existingCase) {
      return res.status(404).json({ error: 'Case not found' });
    }

    const oldStatus = existingCase.status;
    let newStatus = oldStatus;
    let notesUpdate = existingCase.notes;

    const allowedClosureReasons = [
      'False Alarm',
      'Victim Safe',
      'Police Intervention',
      'Emergency Resolved',
      'Duplicate Case',
      'Other'
    ];

    if (status) {
      newStatus = status;
      if (status === 'Resolved' && oldStatus !== 'Resolved') {
        if (!closureReason || !String(closureReason).trim()) {
          return res.status(400).json({ error: 'A closure reason is required when resolving a case' });
        }
        if (!allowedClosureReasons.includes(closureReason)) {
          return res.status(400).json({ error: 'Invalid closure reason' });
        }
        await auditLog(req.user.userId, existingCase.id, 'CASE_CLOSED', `Case resolved. Reason: ${closureReason}`);
      }
      if (oldStatus !== status) {
        await auditLog(req.user.userId, existingCase.id, 'CASE_STATUS_CHANGED', `Status changed from ${oldStatus} to ${status}`);
      }
    }

    if (notes !== undefined) {
      notesUpdate = notes;
      await auditLog(req.user.userId, existingCase.id, 'CASE_NOTES_UPDATED', 'Case notes updated');
    }

    const closureReasonValue = closureReason && String(closureReason).trim() && newStatus === 'Resolved'
      ? String(closureReason).trim()
      : existingCase.closure_reason;

    await query(
      'UPDATE sos_cases SET status = $1, notes = $2, closure_reason = $3, first_response_at = COALESCE(first_response_at, now()), updated_at = $4 WHERE id = $5',
      [newStatus, notesUpdate, closureReasonValue, updatedAt, req.params.id]
    );

    const updatedCases = await query('SELECT * FROM sos_cases WHERE id = $1', [req.params.id]);

    const mappedCase = await mapCase(updatedCases[0]);

    emitCaseUpdated(mappedCase);

    res.json({
      message: 'Case updated successfully',
      case: mappedCase
    });
  } catch (error) {
    console.error('Update case error:', error);
    res.status(500).json({ error: 'Error updating case' });
  }
});

router.put('/:id/location', authMiddleware, async (req, res) => {
  try {
    const { latitude, longitude, locationLink } = req.body;

    const existingCases = await query('SELECT * FROM sos_cases WHERE id = $1', [req.params.id]);
    const existingCase = existingCases[0];

    if (!existingCase) {
      return res.status(404).json({ error: 'Case not found' });
    }

    if (existingCase.user_id !== req.user.userId) {
      return res.status(403).json({ error: 'Access denied' });
    }

    if (existingCase.status !== 'Pending') {
      return res.status(400).json({ error: 'Case is not active' });
    }

    const latValue = latitude && String(latitude).trim() ? String(latitude).trim() : existingCase.latitude;
    const lngValue = longitude && String(longitude).trim() ? String(longitude).trim() : existingCase.longitude;
    const locValue = locationLink && String(locationLink).trim() ? String(locationLink).trim() : existingCase.location_link;
    const updatedAt = new Date();

    await query(
      'UPDATE sos_cases SET latitude = $1, longitude = $2, location_link = $3, updated_at = $4 WHERE id = $5',
      [latValue, lngValue, locValue, updatedAt, req.params.id]
    );

    await auditLog(req.user.userId, existingCase.id, 'LOCATION_UPDATED', `Location updated to ${latValue}, ${lngValue}`);

    res.json({
      message: 'Location updated',
      location: {
        latitude: latValue,
        longitude: lngValue,
        locationLink: locValue,
        updatedAt
      }
    });
  } catch (error) {
    console.error('Update location error:', error);
    res.status(500).json({ error: 'Error updating location' });
  }
});

module.exports = router;