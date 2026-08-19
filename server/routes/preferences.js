const express = require('express');
const { authMiddleware } = require('../middleware/auth');
const { query } = require('../db');

const router = express.Router();

const DEFAULT_PHRASES = ['help me'];

const validatePhrases = (phrases) => {
  if (!Array.isArray(phrases)) return null;
  if (phrases.length > 10) return null;
  const cleaned = phrases.map((p) => (typeof p === 'string' ? p.trim() : '')).filter((p) => p.length > 0 && p.length <= 50);
  if (cleaned.length === 0) return null;
  return [...new Set(cleaned)];
};

router.get('/', authMiddleware, async (req, res) => {
  try {
    const rows = await query('SELECT voice_phrases FROM user_preferences WHERE user_id = $1', [req.user.userId]);
    if (rows.length === 0) {
      return res.json({ voicePhrases: DEFAULT_PHRASES });
    }
    const stored = rows[0].voice_phrases;
    const phrases = Array.isArray(stored) ? stored : DEFAULT_PHRASES;
    res.json({ voicePhrases: phrases });
  } catch (error) {
    console.error('Get preferences error:', error);
    res.status(500).json({ error: 'Error fetching preferences' });
  }
});

router.put('/', authMiddleware, async (req, res) => {
  try {
    console.log('[PREFS] PUT request received:', { userId: req.user?.userId, bodyKeys: Object.keys(req.body || {}), rawPhrases: req.body?.voicePhrases, contentType: req.headers['content-type'] });
    const phrases = validatePhrases(req.body.voicePhrases);
    if (!phrases) {
      console.warn('[PREFS] Validation failed:', { rawPhrases: req.body?.voicePhrases, type: typeof req.body?.voicePhrases, isArray: Array.isArray(req.body?.voicePhrases) });
      return res.status(400).json({ error: 'voicePhrases must be an array of 1-10 non-empty strings (max 50 chars each)' });
    }
    console.log('[PREFS] Validation passed, saving:', { userId: req.user.userId, count: phrases.length, phrases });
    await query(
      `INSERT INTO user_preferences (user_id, voice_phrases)
       VALUES ($1, $2::jsonb)
       ON CONFLICT (user_id) DO UPDATE SET voice_phrases = EXCLUDED.voice_phrases`,
      [req.user.userId, JSON.stringify(phrases)]
    );
    res.json({ voicePhrases: phrases });
  } catch (error) {
    console.error('Update preferences error:', error);
    res.status(500).json({ error: 'Error updating preferences' });
  }
});

module.exports = router;