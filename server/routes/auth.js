const express = require('express');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { query, auditLog } = require('../db');
const storage = require('../storage');
const { JWT_SECRET, authMiddleware } = require('../middleware/auth');
const emailService = require('../services/email');

const router = express.Router();

const generateOTP = () => {
  return Math.floor(100000 + Math.random() * 900000).toString();
};

const OTP_EXPIRY_MINUTES = 5;

const buildGuardianBase = (name) => {
  let base = (name || '').toLowerCase().replace(/[^a-z0-9]/g, '');
  if (!base || base.length < 3) base = 'user';
  return base;
};

// users.email has a UNIQUE constraint (see server/sql/schema.sql `Email UNIQUE`;
// Postgres reports it as code 23505, MySQL as ER_DUP_ENTRY/1062).
// A SELECT-then-INSERT can never be race-free under concurrency, so callers
// must treat this as best-effort candidate generation and retry the
// INSERT/UPDATE on unique-violation with a fresh suffix (see register below).
const generateGuardianEmail = async (name) => {
  const base = buildGuardianBase(name);

  let guardianEmail = base + '@guardian.com';
  const existing = await query('SELECT * FROM users WHERE email = $1', [guardianEmail]);
  if (existing.length === 0) return guardianEmail;

  for (let i = 1; i < 100; i++) {
    guardianEmail = base + i + '@guardian.com';
    const found = await query('SELECT * FROM users WHERE email = $1', [guardianEmail]);
    if (found.length === 0) return guardianEmail;
  }

  return base + Date.now() + '@guardian.com';
};

// Retryable only when the violated constraint is users.email. A violation on
// personal_email means a real duplicate registration and must NOT be retried
// with a new guardian email.
const isEmailUniqueViolation = (error) => {
  if (!error) return false;
  if (error.code === '23505') {
    const detail = String(error.detail || '').toLowerCase();
    const constraint = String(error.constraint || '').toLowerCase();
    if (detail.includes('personal_email') || constraint.includes('personal_email')) return false;
    return true;
  }
  if (error.code === 'ER_DUP_ENTRY' || error.errno === 1062) {
    const msg = String(error.message || '').toLowerCase();
    if (msg.includes('personal_email') || msg.includes('personalemail')) return false;
    return true;
  }
  return false;
};

// Fresh candidate that does not require a SELECT round-trip; used only after
// a unique-violation proves the best-effort candidate collided.
const freshGuardianEmailOnCollision = (name, attempt) => {
  const base = buildGuardianBase(name);
  return `${base}${Date.now()}${attempt}${Math.floor(Math.random() * 1000)}@guardian.com`;
};

router.get('/me', authMiddleware, async (req, res) => {
  try {
    const users = await query('SELECT * FROM users WHERE id = $1', [req.user.userId]);
    const user = users[0];

    if (!user) {
      return res.status(404).json({ error: 'User not found' });
    }

    res.json({
      user: {
        id: user.id,
        name: user.name,
        email: user.email,
        role: user.role
      }
    });
  } catch (error) {
    console.error('Me error:', error);
    res.status(500).json({ error: 'Server error fetching user' });
  }
});

router.put('/me', authMiddleware, async (req, res) => {
  try {
    const { name, currentPassword, password } = req.body;
    const users = await query('SELECT * FROM users WHERE id = $1', [req.user.userId]);
    const user = users[0];

    if (!user) {
      return res.status(404).json({ error: 'User not found' });
    }

    const updates = [];
    const params = [];

    if (name !== undefined) {
      if (typeof name !== 'string' || !name.trim()) {
        return res.status(400).json({ error: 'Name is required' });
      }
      updates.push(`name = $${params.length + 1}`);
      params.push(name.trim());
    }

    if (password !== undefined) {
      if (typeof password !== 'string' || password.length < 6) {
        return res.status(400).json({ error: 'New password must be at least 6 characters' });
      }
      if (!currentPassword || typeof currentPassword !== 'string') {
        return res.status(400).json({ error: 'Current password is required to change password' });
      }
      const valid = await bcrypt.compare(currentPassword, user.password);
      if (!valid) {
        return res.status(400).json({ error: 'Current password is incorrect' });
      }
      const hashed = await bcrypt.hash(password, 10);
      updates.push(`password = $${params.length + 1}`);
      params.push(hashed);
    }

    if (updates.length === 0) {
      return res.status(400).json({ error: 'Nothing to update' });
    }

    updates.push(`updated_at = now()`);
    params.push(req.user.userId);
    const updated = await query(
      `UPDATE users SET ${updates.join(', ')} WHERE id = $${params.length} RETURNING id, name, email, role`,
      params
    );

    if (password !== undefined) {
      await auditLog(req.user.userId, null, 'PASSWORD_CHANGED', 'User changed their password');
    }
    if (name !== undefined) {
      await auditLog(req.user.userId, null, 'PROFILE_UPDATED', 'User updated their name');
    }

    res.json({ message: 'Profile updated successfully', user: updated[0] });
  } catch (error) {
    console.error('Update me error:', error);
    res.status(500).json({ error: 'Server error updating profile' });
  }
});

router.get('/me/export', authMiddleware, async (req, res) => {
  try {
    const userId = req.user.userId;

    const users = await query('SELECT * FROM users WHERE id = $1', [userId]);
    const user = users[0];
    if (!user) {
      return res.status(404).json({ error: 'User not found' });
    }

    const cases = await query(
      `SELECT id, user_id, user_email, location_link, latitude, longitude, status, notes,
              video_url, audio_url, trigger_type, priority, case_type, assigned_officer,
              closure_reason, first_response_at, created_at, updated_at
         FROM sos_cases WHERE user_id = $1 ORDER BY created_at DESC`,
      [userId]
    );

    const contacts = await query(
      `SELECT id, user_id, name, phone, email, relation, priority, created_at, updated_at
         FROM contacts WHERE user_id = $1 ORDER BY priority ASC, created_at ASC`,
      [userId]
    );

    const exportedCases = await Promise.all(cases.map(async (c) => ({
      ...c,
      video_url: await storage.resolveUrl(c.video_url),
      audio_url: await storage.resolveUrl(c.audio_url)
    })));

    res.json({
      exportedAt: new Date().toISOString(),
      profile: {
        id: user.id,
        name: user.name,
        email: user.email,
        personalEmail: user.personal_email,
        role: user.role,
        isVerified: user.is_verified,
        createdAt: user.created_at,
        updatedAt: user.updated_at
      },
      cases: exportedCases,
      contacts
    });
  } catch (error) {
    console.error('Export error:', error);
    res.status(500).json({ error: 'Server error exporting data' });
  }
});

router.post('/register', async (req, res) => {
  try {
    const { name, personalEmail, password, role } = req.body;

    if (!name || !personalEmail || !password) {
      return res.status(400).json({ error: 'Name, personal email and password are required' });
    }

    if (role === 'police' || role === 'admin') {
      return res.status(403).json({ error: 'Police and admin accounts cannot be self-registered' });
    }

    const existingByPersonalEmail = await query('SELECT * FROM users WHERE personal_email = $1', [personalEmail]);
    const existingPersonalUser = existingByPersonalEmail[0];

    if (existingPersonalUser) {
      if (existingPersonalUser.is_verified) {
        return res.status(400).json({ error: 'This personal email is already registered. Please login with your Guardian ID.' });
      }

      let newGuardianEmail = await generateGuardianEmail(name);
      const otp = generateOTP();
      const otpExpiry = new Date(Date.now() + OTP_EXPIRY_MINUTES * 60 * 1000);
      const hashedReRegPassword = await bcrypt.hash(password, 10);

      // Collision-safe: concurrent same-name re-registers may pick the same
      // candidate email; on users.email unique-violation retry with a fresh suffix.
      let reRegUpdated = false;
      for (let attempt = 0; attempt < 6 && !reRegUpdated; attempt++) {
        try {
          await query(
            'UPDATE users SET name = $1, email = $2, password = $3, role = $4, updated_at = now(), otp = $5, otp_expiry = $6 WHERE id = $7',
            [name, newGuardianEmail, hashedReRegPassword, 'user', otp, otpExpiry, existingPersonalUser.id]
          );
          reRegUpdated = true;
        } catch (err) {
          if (isEmailUniqueViolation(err) && attempt < 5) {
            newGuardianEmail = freshGuardianEmailOnCollision(name, attempt);
            continue;
          }
          throw err;
        }
      }

      const emailResult = await emailService.sendOTPEmail(personalEmail, name, otp);
      if (!emailResult.success) {
        console.error('OTP email failed (re-register):', emailResult.error);
      }

      return res.status(201).json({
        message: emailResult.success
          ? 'Verification OTP sent to your personal email'
          : 'Account updated, but the OTP email could not be sent. Please use Resend OTP.',
        guardianEmail: newGuardianEmail,
        personalEmail,
        requiresVerification: true,
        emailSent: emailResult.success
      });
    }

    let guardianEmail = await generateGuardianEmail(name);
    const hashedPassword = await bcrypt.hash(password, 10);
    const userRole = 'user';
    const otp = generateOTP();
    const otpExpiry = new Date(Date.now() + OTP_EXPIRY_MINUTES * 60 * 1000);

    // Collision-safe: concurrent same-name registers pass the SELECT check
    // with the same candidate, then one INSERT hits the users.email UNIQUE
    // constraint (23505). Retry with a fresh suffix instead of 500ing.
    let result = null;
    for (let attempt = 0; attempt < 6; attempt++) {
      try {
        result = await query(
          `INSERT INTO users (name, email, personal_email, password, role, created_at, updated_at, is_verified, otp, otp_expiry)
           VALUES ($1, $2, $3, $4, $5, now(), now(), false, $6, $7) RETURNING id`,
          [name, guardianEmail, personalEmail, hashedPassword, userRole, otp, otpExpiry]
        );
        break;
      } catch (err) {
        if (isEmailUniqueViolation(err) && attempt < 5) {
          guardianEmail = freshGuardianEmailOnCollision(name, attempt);
          continue;
        }
        throw err;
      }
    }

    const insertId = result[0].id;

    await auditLog(insertId, null, 'USER_REGISTERED', `New user registered: ${guardianEmail} (via ${personalEmail}) - pending verification`);

    const emailResult = await emailService.sendOTPEmail(personalEmail, name, otp);
    if (!emailResult.success) {
      console.error('OTP email failed (register):', emailResult.error);
    }

    res.status(201).json({
      message: emailResult.success
        ? 'Registration successful! Please check your personal email for the verification OTP.'
        : 'Registration successful, but the OTP email could not be sent. Please use Resend OTP.',
      requiresVerification: true,
      guardianEmail,
      personalEmail,
      emailSent: emailResult.success
    });
  } catch (error) {
    console.error('Register error:', error.code || '', error.message);
    if (error.code === 'NO_DATABASE_URL' || error.message?.includes('DATABASE_URL not configured')) {
      return res.status(500).json({ error: 'Server misconfigured: DATABASE_URL not set.' });
    }
    const rmsg = (error.message || '').toLowerCase();
    if (error.code === 'XX000' || rmsg.includes('tenant') || rmsg.includes('enotfound') || rmsg.includes('not found')) {
      return res.status(500).json({ error: `Database unreachable: ${error.message}. Check DATABASE_URL user is postgres.<project_ref>.` });
    }
    res.status(500).json({ error: `Server error during registration: ${error.code || ''} ${error.message}`.trim() });
  }
});

router.post('/verify-otp', async (req, res) => {
  try {
    const { personalEmail, otp } = req.body;

    if (!personalEmail || !otp) {
      return res.status(400).json({ error: 'Personal email and OTP are required' });
    }

    const users = await query('SELECT * FROM users WHERE personal_email = $1', [personalEmail]);
    const user = users[0];

    if (!user) {
      return res.status(404).json({ error: 'User not found' });
    }

    if (user.is_verified) {
      return res.status(400).json({ error: 'Email already verified. Please login.' });
    }

    if (!user.otp || user.otp !== otp) {
      return res.status(400).json({ error: 'Invalid OTP' });
    }

    const now = new Date();
    const expiry = new Date(user.otp_expiry);
    if (now > expiry) {
      return res.status(400).json({ error: 'OTP has expired. Please request a new one.' });
    }

    await query(
      'UPDATE users SET is_verified = true, otp = NULL, otp_expiry = NULL, updated_at = now() WHERE id = $1',
      [user.id]
    );

    await auditLog(user.id, null, 'EMAIL_VERIFIED', `Personal email verified: ${personalEmail} for guardian: ${user.email}`);

    res.json({
      message: 'Email verified successfully! You can now login with your Guardian ID.',
      verified: true,
      guardianEmail: user.email
    });
  } catch (error) {
    console.error('Verify OTP error:', error);
    res.status(500).json({ error: 'Server error during OTP verification' });
  }
});

router.post('/resend-otp', async (req, res) => {
  try {
    const { personalEmail } = req.body;

    if (!personalEmail) {
      return res.status(400).json({ error: 'Personal email is required' });
    }

    const users = await query('SELECT * FROM users WHERE personal_email = $1', [personalEmail]);
    const user = users[0];

    if (!user) {
      return res.status(404).json({ error: 'User not found' });
    }

    if (user.is_verified) {
      return res.status(400).json({ error: 'Email already verified. Please login.' });
    }

    const otp = generateOTP();
    const otpExpiry = new Date(Date.now() + OTP_EXPIRY_MINUTES * 60 * 1000);

    await query(
      'UPDATE users SET otp = $1, otp_expiry = $2, updated_at = now() WHERE id = $3',
      [otp, otpExpiry, user.id]
    );

    const emailResult = await emailService.sendOTPEmail(personalEmail, user.name, otp);
    if (!emailResult.success) {
      console.error('OTP email failed (resend):', emailResult.error);
      return res.status(502).json({
        error: 'Could not send the OTP email right now. Please try again shortly.',
        emailSent: false
      });
    }

    res.json({
      message: 'New OTP sent to your personal email',
      emailSent: true
    });
  } catch (error) {
    console.error('Resend OTP error:', error);
    res.status(500).json({ error: 'Server error during OTP resend' });
  }
});

router.post('/login', async (req, res) => {
  try {
    const { email, password } = req.body;

    if (!email || !password) {
      return res.status(400).json({ error: 'Guardian ID and password are required' });
    }

    const users = await query('SELECT * FROM users WHERE email = $1', [email]);
    const user = users[0];

    if (!user) {
      return res.status(401).json({ error: 'Invalid Guardian ID or password' });
    }

    if (!user.is_verified) {
      const otp = generateOTP();
      const otpExpiry = new Date(Date.now() + OTP_EXPIRY_MINUTES * 60 * 1000);

      await query(
        'UPDATE users SET otp = $1, otp_expiry = $2, updated_at = now() WHERE id = $3',
        [otp, otpExpiry, user.id]
      );

      const emailResult = await emailService.sendOTPEmail(user.personal_email, user.name, otp);
      if (!emailResult.success) {
        console.error('OTP email failed (login-unverified):', emailResult.error);
      }

      return res.status(403).json({
        error: emailResult.success
          ? 'Please verify your email first. A new OTP has been sent to your personal email.'
          : 'Please verify your email first. The OTP email could not be sent; please use Resend OTP.',
        requiresVerification: true,
        personalEmail: user.personal_email,
        emailSent: emailResult.success
      });
    }

    const isMatch = await bcrypt.compare(password, user.password);
    if (!isMatch) {
      return res.status(401).json({ error: 'Invalid Guardian ID or password' });
    }

    await auditLog(user.id, null, 'USER_LOGIN', `User logged in: ${email} (Role: ${user.role})`);

    const token = jwt.sign(
      { userId: user.id, email: user.email, role: user.role },
      JWT_SECRET,
      { expiresIn: '7d' }
    );

    res.json({
      message: 'Login successful',
      token,
      user: {
        id: user.id,
        name: user.name,
        email: user.email,
        role: user.role
      }
    });
  } catch (error) {
    console.error('Login error:', error.code || '', error.message, error.stack?.split('\n')[1] || '');
    // Return actionable error instead of generic 500
    if (error.code === 'NO_DATABASE_URL' || error.message?.includes('DATABASE_URL not configured')) {
      return res.status(500).json({ error: 'Server misconfigured: DATABASE_URL not set. Admin must set it in Render → Environment.' });
    }
    // Supabase pooler returns XX000 with message containing ENOTFOUND/tenant not found when user is wrong — check message first for actionable hint
    const msg = (error.message || '').toLowerCase();
    if (msg.includes('enotfound') || msg.includes('tenant') || msg.includes('not found') || msg.includes('getaddrinfo')) {
      return res.status(500).json({ error: `Database unreachable: ${error.message}. Check DATABASE_URL user is postgres.<project_ref> (not zelda_app) and host is correct. | code=${error.code}` });
    }
    if (error.code === 'ECONNREFUSED' || error.code === 'ETIMEDOUT' || error.code === 'ENOTFOUND' || error.code === 'XX000') {
      return res.status(500).json({ error: `Database unreachable (${error.code}): ${error.message}. Supabase may be paused or DATABASE_URL host/user is wrong.` });
    }
    if (error.message?.includes('password authentication failed') || error.code === '28P01') {
      return res.status(500).json({ error: 'Database password incorrect — update DATABASE_URL with correct Supabase password.' });
    }
    // Fallback — always include code+message (even in production) so Render logs + client can debug
    res.status(500).json({ error: `Server error during login: ${error.code || ''} ${error.message}`.trim() });
  }
});

module.exports = router;
module.exports.generateGuardianEmail = generateGuardianEmail;
