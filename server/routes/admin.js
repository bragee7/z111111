const express = require('express');
const bcrypt = require('bcryptjs');
const { pool, query, auditLog } = require('../db');
const { authMiddleware, requireAdmin } = require('../middleware/auth');
const { supabase, MEDIA_BUCKET } = require('../supabase');
const { generateGuardianEmail } = require('./auth');

const router = express.Router();

router.use(authMiddleware);
router.use(requireAdmin);

const mapUser = (u) => ({
  id: u.id,
  name: u.name,
  email: u.email,
  personalEmail: u.personal_email,
  role: u.role,
  isVerified: u.is_verified,
  createdAt: u.created_at,
  updatedAt: u.updated_at
});

const mapCase = (c) => ({
  id: c.id,
  userId: c.user_id,
  userEmail: c.user_email,
  locationLink: c.location_link,
  latitude: c.latitude,
  longitude: c.longitude,
  status: c.status,
  priority: c.priority,
  caseType: c.case_type,
  assignedOfficer: c.assigned_officer,
  notes: c.notes,
  videoUrl: c.video_url,
  audioUrl: c.audio_url,
  triggerType: c.trigger_type,
  timestamp: c.created_at,
  createdAt: c.created_at,
  updatedAt: c.updated_at,
  waitingDuration: c.waiting_duration,
  resolutionTime: c.resolution_time,
  resolvedAt: c.resolved_at,
  nearestPoliceStationName: c.nearest_police_station_name ?? null,
  nearestPoliceStationAddress: c.nearest_police_station_address ?? null,
  nearestPoliceStationLat: c.nearest_police_station_lat ?? null,
  nearestPoliceStationLng: c.nearest_police_station_lng ?? null,
  nearestPoliceStationDistanceM: c.nearest_police_station_distance_m ?? null,
  nearestPoliceStationOsmId: c.nearest_police_station_osm_id ?? null,
  nearestPoliceStationOsmType: c.nearest_police_station_osm_type ?? null,
  nearestPoliceStationFetchedAt: c.nearest_police_station_fetched_at ?? null,
});

const mapContact = (c) => ({
  id: c.id,
  userId: c.user_id,
  userEmail: c.user_email,
  userName: c.user_name,
  name: c.name,
  phone: c.phone,
  email: c.email,
  relation: c.relation,
  createdAt: c.created_at,
  updatedAt: c.updated_at
});

const deleteUserMedia = async (caseRows) => {
  if (!supabase) return;
  const fileNames = new Set();

  for (const c of caseRows) {
    for (const url of [c.video_url, c.audio_url]) {
      if (!url) continue;
      try {
        const clean = String(url).split('?')[0];
        const fileName = clean.split('/').pop();
        if (fileName) fileNames.add(fileName);
      } catch (_) {}
    }
  }

  if (fileNames.size === 0) return;

  await supabase.storage
    .from(MEDIA_BUCKET)
    .remove([...fileNames])
    .then(() => {})
    .catch((err) => console.error('Media deletion error:', err.message));
};

router.get('/stats/overview', async (req, res) => {
  try {
    const totalUsers = await query('SELECT COUNT(*)::int AS count FROM users');
    const totalCases = await query('SELECT COUNT(*)::int AS count FROM sos_cases');
    const pendingCases = await query("SELECT COUNT(*)::int AS count FROM sos_cases WHERE status = 'Pending'");
    const resolvedCases = await query("SELECT COUNT(*)::int AS count FROM sos_cases WHERE status = 'Resolved'");
    const casesToday = await query('SELECT COUNT(*)::int AS count FROM sos_cases WHERE created_at::date = CURRENT_DATE');
    const usersToday = await query('SELECT COUNT(*)::int AS count FROM users WHERE created_at::date = CURRENT_DATE');
    const totalContacts = await query('SELECT COUNT(*)::int AS count FROM contacts');
    const auditCount = await query('SELECT COUNT(*)::int AS count FROM audit_log');
    const avgResponseMinutes = await query("SELECT ROUND(AVG(EXTRACT(EPOCH FROM (first_response_at - created_at))/60)::numeric,1)::float AS avg FROM sos_cases WHERE first_response_at IS NOT NULL");

    res.json({
      totalUsers: totalUsers[0].count,
      totalCases: totalCases[0].count,
      pendingCases: pendingCases[0].count,
      resolvedCases: resolvedCases[0].count,
      casesToday: casesToday[0].count,
      usersToday: usersToday[0].count,
      totalContacts: totalContacts[0].count,
      auditCount: auditCount[0].count,
      avgResponseMinutes: avgResponseMinutes[0].avg
    });
  } catch (error) {
    console.error('Admin overview error:', error);
    res.status(500).json({ error: 'Error fetching stats' });
  }
});

router.get('/stats/registrations', async (req, res) => {
  try {
    const days = Math.min(Math.max(parseInt(req.query.days) || 30, 1), 90);
    const rows = await query(
      `SELECT d.day, COALESCE(COUNT(u.id), 0)::int AS count
       FROM generate_series(CURRENT_DATE - ($1::int - 1), CURRENT_DATE, '1 day'::interval) AS d(day)
       LEFT JOIN users u ON u.created_at::date = d.day
       GROUP BY d.day
       ORDER BY d.day ASC`,
      [days]
    );
    res.json({ days, series: rows });
  } catch (error) {
    console.error('Admin registrations error:', error);
    res.status(500).json({ error: 'Error fetching registration stats' });
  }
});

router.get('/stats/cases-by-day', async (req, res) => {
  try {
    const days = Math.min(Math.max(parseInt(req.query.days) || 30, 1), 90);
    const rows = await query(
      `SELECT d.day, COALESCE(COUNT(c.id), 0)::int AS count
       FROM generate_series(CURRENT_DATE - ($1::int - 1), CURRENT_DATE, '1 day'::interval) AS d(day)
       LEFT JOIN sos_cases c ON c.created_at::date = d.day
       GROUP BY d.day
       ORDER BY d.day ASC`,
      [days]
    );
    res.json({ days, series: rows });
  } catch (error) {
    console.error('Admin cases-by-day error:', error);
    res.status(500).json({ error: 'Error fetching case stats' });
  }
});

router.get('/stats/response-times', async (req, res) => {
  try {
    const overallRow = await query(
      `SELECT COUNT(*)::int AS responded_count,
              ROUND(AVG(EXTRACT(EPOCH FROM (first_response_at - created_at)) / 60)::numeric, 1)::float AS avg_minutes,
              MAX(EXTRACT(EPOCH FROM (first_response_at - created_at)) / 60)::float AS max_minutes
       FROM sos_cases
       WHERE first_response_at IS NOT NULL`
    );
    const perOfficerRows = await query(
      `SELECT assigned_officer AS officer,
              COUNT(*)::int AS cases,
              ROUND(AVG(EXTRACT(EPOCH FROM (first_response_at - created_at)) / 60)::numeric, 1)::float AS avg_minutes,
              MAX(EXTRACT(EPOCH FROM (first_response_at - created_at)) / 60)::float AS max_minutes
       FROM sos_cases
       WHERE first_response_at IS NOT NULL
         AND assigned_officer IS NOT NULL
         AND assigned_officer <> ''
       GROUP BY assigned_officer
       ORDER BY avg_minutes ASC`
    );
    res.json({ overall: overallRow[0], perOfficer: perOfficerRows });
  } catch (error) {
    console.error('Admin response-times error:', error);
    res.status(500).json({ error: 'Error fetching response time stats' });
  }
});

router.get('/stats/officer-kpis', async (req, res) => {
  try {
    const rows = await query(
      `SELECT assigned_officer AS officer,
              COUNT(*)::int AS cases_handled,
              COUNT(*) FILTER (WHERE status = 'Resolved')::int AS resolved_count,
              COUNT(*) FILTER (WHERE status = 'Pending')::int AS pending_count,
              ROUND(AVG(EXTRACT(EPOCH FROM (first_response_at - created_at)) / 60)::numeric, 1)::float AS avg_response_minutes
       FROM sos_cases
       WHERE assigned_officer IS NOT NULL
         AND assigned_officer <> ''
       GROUP BY assigned_officer
       ORDER BY cases_handled DESC`
    );
    res.json({ officers: rows });
  } catch (error) {
    console.error('Admin officer-kpis error:', error);
    res.status(500).json({ error: 'Error fetching officer KPIs' });
  }
});

router.get('/stats/status-distribution', async (req, res) => {
  try {
    const rows = await query(
      `SELECT status, COUNT(*)::int AS count
       FROM sos_cases
       GROUP BY status
       ORDER BY count DESC`
    );
    res.json({ distribution: rows });
  } catch (error) {
    console.error('Admin status-distribution error:', error);
    res.status(500).json({ error: 'Error fetching status distribution' });
  }
});

router.get('/stats/series', async (req, res) => {
  try {
    const period = req.query.period === 'month' ? 'month' : 'week';
    const buckets = period === 'month' ? 6 : 8;
    const rows = await query(
      `SELECT to_char(d.day, 'YYYY-MM-DD') AS day, COUNT(s.id)::int AS count
       FROM generate_series(
         date_trunc('${period}', CURRENT_DATE) - (($1::int - 1) * interval '1 ${period}'),
         date_trunc('${period}', CURRENT_DATE),
         interval '1 ${period}'
       ) AS d(day)
       LEFT JOIN sos_cases s ON date_trunc('${period}', s.created_at) = d.day
       GROUP BY d.day
       ORDER BY d.day ASC`,
      [buckets]
    );
    res.json({ period, buckets, series: rows });
  } catch (error) {
    console.error('Admin series error:', error);
    res.status(500).json({ error: 'Error fetching case series' });
  }
});

router.get('/stats/geo', async (req, res) => {
  try {
    const rows = await query(
      `SELECT latitude, longitude
       FROM sos_cases
       WHERE latitude IS NOT NULL AND longitude IS NOT NULL`
    );
    res.json({ points: rows });
  } catch (error) {
    console.error('Admin geo error:', error);
    res.status(500).json({ error: 'Error fetching geo data' });
  }
});

router.get('/stats/cases-by-user', async (req, res) => {
  try {
    const rows = await query(
      `SELECT u.id AS user_id, u.name, u.email, COUNT(c.id)::int AS case_count
       FROM users u
       LEFT JOIN sos_cases c ON c.user_id = u.id
       GROUP BY u.id, u.name, u.email
       ORDER BY case_count DESC, u.email ASC`
    );
    res.json({ users: rows });
  } catch (error) {
    console.error('Admin cases-by-user error:', error);
    res.status(500).json({ error: 'Error fetching case stats' });
  }
});

router.get('/users', async (req, res) => {
  try {
    const page = Math.max(parseInt(req.query.page) || 1, 1);
    const size = Math.min(Math.max(parseInt(req.query.size) || 20, 1), 100);
    const offset = (page - 1) * size;
    const search = (req.query.search || '').trim();
    const statusFilter = req.query.status;
    const todayOnly = req.query.today === '1';

    const conditions = [];
    const params = [];

    if (search) {
      params.push(`%${search}%`);
      conditions.push(`(u.name ILIKE $${params.length} OR u.email ILIKE $${params.length} OR u.personal_email ILIKE $${params.length})`);
    }
    if (statusFilter === 'active') {
      conditions.push('u.is_verified = true');
    } else if (statusFilter === 'inactive') {
      conditions.push('u.is_verified = false');
    }
    if (todayOnly) {
      conditions.push('u.created_at::date = CURRENT_DATE');
    }

    const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';

    const totalRows = await query(
      `SELECT COUNT(*)::int AS count FROM users u ${where}`,
      params
    );
    const total = totalRows[0].count;

    const rows = await query(
      `SELECT u.*,
              (SELECT COUNT(*)::int FROM sos_cases c WHERE c.user_id = u.id) AS case_count,
              (SELECT MAX(a.created_at) FROM audit_log a WHERE a.user_id = u.id) AS last_active
       FROM users u
       ${where}
       ORDER BY u.created_at DESC
       LIMIT $${params.length + 1} OFFSET $${params.length + 2}`,
      [...params, size, offset]
    );

    res.json({
      total,
      page,
      size,
      users: rows.map((u) => ({
        ...mapUser(u),
        caseCount: u.case_count,
        lastActive: u.last_active
      }))
    });
  } catch (error) {
    console.error('Admin users error:', error);
    res.status(500).json({ error: 'Error fetching users' });
  }
});

router.post('/users', async (req, res) => {
  try {
    const { name, personalEmail, password, role } = req.body;

    if (!name || !personalEmail || !password) {
      return res.status(400).json({ error: 'Name, personal email and password are required' });
    }

    const allowedRoles = ['user', 'police', 'admin'];
    const userRole = allowedRoles.includes(role) ? role : 'user';

    if (userRole === 'admin') {
      return res.status(400).json({ error: 'Admin accounts can only be created via the database' });
    }

    const existing = await query('SELECT * FROM users WHERE personal_email = $1', [personalEmail]);
    if (existing.length > 0) {
      return res.status(400).json({ error: 'This personal email is already registered' });
    }

    const guardianEmail = await generateGuardianEmail(name);
    const hashedPassword = await bcrypt.hash(password, 10);

    const result = await query(
      `INSERT INTO users (name, email, personal_email, password, role, created_at, updated_at, is_verified)
       VALUES ($1, $2, $3, $4, $5, now(), now(), true) RETURNING *`,
      [name, guardianEmail, personalEmail, hashedPassword, userRole]
    );

    const user = result[0];
    await auditLog(req.user.userId, null, 'ADMIN_USER_CREATED', `Admin ${req.user.email} created user ${guardianEmail} (role: ${userRole})`);

    res.status(201).json({ message: 'User created successfully', user: mapUser(user) });
  } catch (error) {
    console.error('Admin create user error:', error);
    res.status(500).json({ error: 'Error creating user' });
  }
});

router.delete('/users/:id', async (req, res) => {
  const client = await pool.connect();
  try {
    const users = await query('SELECT * FROM users WHERE id = $1', [req.params.id]);
    const user = users[0];

    if (!user) {
      return res.status(404).json({ error: 'User not found' });
    }

    if (user.role === 'admin') {
      return res.status(400).json({ error: 'Cannot delete an admin account' });
    }

    const caseRows = await query('SELECT video_url, audio_url FROM sos_cases WHERE user_id = $1', [user.id]);

    let deletedCases = 0;
    let deletedContacts = 0;
    let deletedAudit = 0;
    let deletedUser = 0;

    await client.query('BEGIN');
    try {
      const casesRes = await client.query('DELETE FROM sos_cases WHERE user_id = $1', [user.id]);
      deletedCases = casesRes.rowCount;
      const contactsRes = await client.query('DELETE FROM contacts WHERE user_id = $1', [user.id]);
      deletedContacts = contactsRes.rowCount;
      const auditRes = await client.query('DELETE FROM audit_log WHERE user_id = $1', [user.id]);
      deletedAudit = auditRes.rowCount;
      const userRes = await client.query('DELETE FROM users WHERE id = $1', [user.id]);
      deletedUser = userRes.rowCount;
      await client.query('COMMIT');
    } catch (err) {
      await client.query('ROLLBACK');
      throw err;
    }

    deleteUserMedia(caseRows);

    res.json({
      message: 'User deleted successfully',
      deleted: { user: deletedUser, cases: deletedCases, contacts: deletedContacts, auditLog: deletedAudit }
    });
  } catch (error) {
    console.error('Admin delete user error:', error);
    res.status(500).json({ error: 'Error deleting user' });
  } finally {
    client.release();
  }
});

router.get('/cases', async (req, res) => {
  try {
    const page = Math.max(parseInt(req.query.page) || 1, 1);
    const size = Math.min(Math.max(parseInt(req.query.size) || 20, 1), 200);
    const offset = (page - 1) * size;
    const { status, priority, type, search, today } = req.query;

    const conditions = [];
    const params = [];

    if (status && ['Pending', 'Resolved'].includes(status)) {
      params.push(status);
      conditions.push(`status = $${params.length}`);
    }
    if (priority && ['High', 'Medium', 'Low'].includes(priority)) {
      params.push(priority);
      conditions.push(`priority = $${params.length}`);
    }
    if (type && type.trim()) {
      params.push(type.trim());
      conditions.push(`case_type ILIKE $${params.length}`);
    }
    if (search && search.trim()) {
      params.push(`%${search.trim()}%`);
      conditions.push(`(id::text ILIKE $${params.length} OR user_email ILIKE $${params.length} OR location_link ILIKE $${params.length})`);
    }
    if (today === '1') {
      conditions.push('created_at::date = CURRENT_DATE');
    }

    const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';

    const totalRows = await query(
      `SELECT COUNT(*)::int AS count FROM sos_cases ${where}`,
      params
    );
    const total = totalRows[0].count;

    const rows = await query(
      `SELECT c.*,
              CASE WHEN c.status = 'Pending' THEN ROUND(EXTRACT(EPOCH FROM (now() - c.created_at)))::bigint ELSE NULL END AS waiting_duration,
              CASE WHEN c.status = 'Resolved' THEN ROUND(EXTRACT(EPOCH FROM (c.updated_at - c.created_at)))::bigint ELSE NULL END AS resolution_time,
              CASE WHEN c.status = 'Resolved' THEN c.updated_at ELSE NULL END AS resolved_at
       FROM sos_cases c
       ${where}
       ORDER BY c.created_at DESC
       LIMIT $${params.length + 1} OFFSET $${params.length + 2}`,
      [...params, size, offset]
    );

    res.json({ total, page, size, cases: rows.map(mapCase) });
  } catch (error) {
    console.error('Admin cases error:', error);
    res.status(500).json({ error: 'Error fetching cases' });
  }
});

router.get('/cases/:id', async (req, res) => {
  try {
    const rows = await query('SELECT * FROM sos_cases WHERE id = $1', [req.params.id]);
    const caseData = rows[0];

    if (!caseData) {
      return res.status(404).json({ error: 'Case not found' });
    }

    res.json({ case: mapCase(caseData) });
  } catch (error) {
    console.error('Admin get case error:', error);
    res.status(500).json({ error: 'Error fetching case' });
  }
});

router.put('/cases/:id', async (req, res) => {
  try {
    const { status, notes, priority, caseType, assignedOfficer } = req.body;
    const existing = await query('SELECT * FROM sos_cases WHERE id = $1', [req.params.id]);
    const existingCase = existing[0];

    if (!existingCase) {
      return res.status(404).json({ error: 'Case not found' });
    }

    if (status && !['Pending', 'Resolved'].includes(status)) {
      return res.status(400).json({ error: 'Invalid status' });
    }
    if (priority && !['High', 'Medium', 'Low'].includes(priority)) {
      return res.status(400).json({ error: 'Invalid priority' });
    }

    const oldStatus = existingCase.status;
    const newStatus = status || oldStatus;
    const newNotes = notes !== undefined ? notes : existingCase.notes;
    const newPriority = priority || existingCase.priority;
    const newType = caseType !== undefined && caseType.trim() ? caseType.trim() : existingCase.case_type;
    const newOfficer = assignedOfficer !== undefined && assignedOfficer.trim() ? assignedOfficer.trim() : existingCase.assigned_officer;

    if (status && oldStatus !== status) {
      await auditLog(req.user.userId, existingCase.id, 'ADMIN_CASE_STATUS_CHANGED', `Admin ${req.user.email}: status changed from ${oldStatus} to ${status}`);
    }
    if (priority && existingCase.priority !== priority) {
      await auditLog(req.user.userId, existingCase.id, 'ADMIN_CASE_PRIORITY_CHANGED', `Admin ${req.user.email}: priority changed from ${existingCase.priority} to ${priority}`);
    }
    if (notes !== undefined && notes !== existingCase.notes) {
      await auditLog(req.user.userId, existingCase.id, 'ADMIN_CASE_NOTES_UPDATED', `Admin ${req.user.email}: notes updated`);
    }

    await query(
      `UPDATE sos_cases
       SET status = $1, notes = $2, priority = $3, case_type = $4, assigned_officer = $5, first_response_at = COALESCE(first_response_at, now()), updated_at = now()
       WHERE id = $6`,
      [newStatus, newNotes, newPriority, newType, newOfficer, req.params.id]
    );

    const updated = await query('SELECT * FROM sos_cases WHERE id = $1', [req.params.id]);
    res.json({ message: 'Case updated successfully', case: mapCase(updated[0]) });
  } catch (error) {
    console.error('Admin update case error:', error);
    res.status(500).json({ error: 'Error updating case' });
  }
});

router.get('/contacts', async (req, res) => {
  try {
    const page = Math.max(parseInt(req.query.page) || 1, 1);
    const size = Math.min(Math.max(parseInt(req.query.size) || 20, 1), 100);
    const offset = (page - 1) * size;
    const search = (req.query.search || '').trim();

    const conditions = [];
    const params = [];

    if (search) {
      params.push(`%${search}%`);
      conditions.push(`(c.name ILIKE $${params.length} OR c.phone ILIKE $${params.length} OR c.email ILIKE $${params.length} OR c.relation ILIKE $${params.length} OR u.email ILIKE $${params.length} OR u.name ILIKE $${params.length})`);
    }

    const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';

    const totalRows = await query(
      `SELECT COUNT(*)::int AS count FROM contacts c LEFT JOIN users u ON u.id = c.user_id ${where}`,
      params
    );
    const total = totalRows[0].count;

    const rows = await query(
      `SELECT c.*, u.email AS user_email, u.name AS user_name
       FROM contacts c
       LEFT JOIN users u ON u.id = c.user_id
       ${where}
       ORDER BY c.created_at DESC
       LIMIT $${params.length + 1} OFFSET $${params.length + 2}`,
      [...params, size, offset]
    );

    res.json({ total, page, size, contacts: rows.map(mapContact) });
  } catch (error) {
    console.error('Admin contacts error:', error);
    res.status(500).json({ error: 'Error fetching contacts' });
  }
});

router.post('/contacts', async (req, res) => {
  try {
    const { userId, name, phone, email, relation } = req.body;

    if (!userId || !name || !phone) {
      return res.status(400).json({ error: 'User ID, name and phone are required' });
    }

    const user = await query('SELECT id FROM users WHERE id = $1', [userId]);
    if (user.length === 0) {
      return res.status(404).json({ error: 'User not found' });
    }

    const result = await query(
      `INSERT INTO contacts (user_id, name, phone, email, relation, created_at, updated_at)
       VALUES ($1, $2, $3, $4, $5, now(), now()) RETURNING *`,
      [userId, name, phone, email || '', relation || '']
    );

    await auditLog(req.user.userId, userId, 'CONTACT_ADDED', `Admin added contact: ${name} (${phone})`);

    const row = await query(
      `SELECT c.*, u.email AS user_email, u.name AS user_name
       FROM contacts c LEFT JOIN users u ON u.id = c.user_id WHERE c.id = $1`,
      [result[0].id]
    );

    res.status(201).json({ message: 'Contact added successfully', contact: mapContact(row[0]) });
  } catch (error) {
    console.error('Admin add contact error:', error);
    res.status(500).json({ error: 'Error adding contact' });
  }
});

router.put('/contacts/:id', async (req, res) => {
  try {
    const { name, phone, email, relation } = req.body;

    const existing = await query('SELECT * FROM contacts WHERE id = $1', [req.params.id]);
    if (existing.length === 0) {
      return res.status(404).json({ error: 'Contact not found' });
    }

    if (name !== undefined && !String(name).trim()) {
      return res.status(400).json({ error: 'Name cannot be empty' });
    }
    if (phone !== undefined && !String(phone).trim()) {
      return res.status(400).json({ error: 'Phone cannot be empty' });
    }

    const result = await query(
      `UPDATE contacts SET
         name = $1, phone = $2, email = $3, relation = $4, updated_at = now()
       WHERE id = $5 RETURNING *`,
      [
        name !== undefined ? name : existing[0].name,
        phone !== undefined ? phone : existing[0].phone,
        email !== undefined ? email : existing[0].email,
        relation !== undefined ? relation : existing[0].relation,
        req.params.id
      ]
    );

    await auditLog(req.user.userId, existing[0].user_id, 'CONTACT_UPDATED', `Admin updated contact: ${result[0].name}`);

    const row = await query(
      `SELECT c.*, u.email AS user_email, u.name AS user_name
       FROM contacts c LEFT JOIN users u ON u.id = c.user_id WHERE c.id = $1`,
      [req.params.id]
    );

    res.json({ message: 'Contact updated successfully', contact: mapContact(row[0]) });
  } catch (error) {
    console.error('Admin update contact error:', error);
    res.status(500).json({ error: 'Error updating contact' });
  }
});

router.delete('/contacts/:id', async (req, res) => {
  try {
    const existing = await query('SELECT * FROM contacts WHERE id = $1', [req.params.id]);
    if (existing.length === 0) {
      return res.status(404).json({ error: 'Contact not found' });
    }

    await query('DELETE FROM contacts WHERE id = $1', [req.params.id]);

    await auditLog(req.user.userId, existing[0].user_id, 'CONTACT_DELETED', `Admin deleted contact: ${existing[0].name}`);

    res.json({ message: 'Contact deleted successfully' });
  } catch (error) {
    console.error('Admin delete contact error:', error);
    res.status(500).json({ error: 'Error deleting contact' });
  }
});

router.get('/audit-log', async (req, res) => {
  try {
    const page = Math.max(parseInt(req.query.page) || 1, 1);
    const size = Math.min(Math.max(parseInt(req.query.size) || 20, 1), 200);
    const offset = (page - 1) * size;
    const search = (req.query.search || '').trim();
    const actionFilter = req.query.action;
    const actorFilter = req.query.actor;

    const conditions = [];
    const params = [];

    if (search) {
      params.push(`%${search}%`);
      conditions.push(`(a.action ILIKE $${params.length} OR a.details ILIKE $${params.length} OR a.id::text ILIKE $${params.length} OR COALESCE(a.case_id::text, '') ILIKE $${params.length})`);
    }
    if (actionFilter && actionFilter.trim()) {
      params.push(actionFilter.trim());
      conditions.push(`a.action ILIKE $${params.length}`);
    }
    if (actorFilter === 'admin') {
      conditions.push("u.role = 'admin'");
    } else if (actorFilter === 'user') {
      conditions.push("u.role = 'user'");
    }

    const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';

    const totalRows = await query(
      `SELECT COUNT(*)::int AS count FROM audit_log a LEFT JOIN users u ON u.id = a.user_id ${where}`,
      params
    );
    const total = totalRows[0].count;

    const rows = await query(
      `SELECT a.id, a.user_id, a.case_id, a.action, a.details, a.created_at,
              u.email AS user_email, u.name AS user_name, u.role AS user_role
       FROM audit_log a
       LEFT JOIN users u ON u.id = a.user_id
       ${where}
       ORDER BY a.created_at DESC
       LIMIT $${params.length + 1} OFFSET $${params.length + 2}`,
      [...params, size, offset]
    );
    res.json({
      total,
      page,
      size,
      entries: rows.map((r) => ({
        id: r.id,
        userId: r.user_id,
        caseId: r.case_id,
        action: r.action,
        details: r.details,
        createdAt: r.created_at,
        userEmail: r.user_email,
        userName: r.user_name,
        userRole: r.user_role
      }))
    });
  } catch (error) {
    console.error('Admin audit-log error:', error);
    res.status(500).json({ error: 'Error fetching audit log' });
  }
});

module.exports = router;