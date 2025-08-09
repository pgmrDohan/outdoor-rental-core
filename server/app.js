// server.js
const express = require('express');
const bodyParser = require('body-parser');
const jwt = require('jsonwebtoken');
const { v4: uuidv4 } = require('uuid');
const sqlite3 = require('sqlite3').verbose();
const path = require('path');
const crypto = require('crypto');

const dbFile = path.resolve(__dirname, 'umbrella.db');
const db = new sqlite3.Database(dbFile, (err) => {
  if (err) console.error('DB open error', err);
});

db.serialize(() => {
  db.run(`CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, name TEXT, passwordHash TEXT)`);
  db.run(`CREATE TABLE IF NOT EXISTS slots (id TEXT PRIMARY KEY, deviceId TEXT, status TEXT)`);
  db.run(`CREATE TABLE IF NOT EXISTS rental_sessions (
    sessionKey TEXT PRIMARY KEY,
    userId TEXT,
    slotId TEXT,
    deviceId TEXT,
    startTs INTEGER,
    returnTs INTEGER,
    overdue INTEGER,
    returned INTEGER,
    ttlTimeout INTEGER
  )`);
  db.run(`CREATE TABLE IF NOT EXISTS used_nonces (nonce TEXT PRIMARY KEY)`);
});

const app = express();
app.use(bodyParser.json());

// Simple test JWT (in production: proper auth)
const jwtSecret = process.env.JWT_SECRET || 'YOUR_JWT_SECRET';

function authMiddleware(req, res, next) {
  const auth = req.headers.authorization;
  if (!auth || !auth.startsWith('Bearer ')) return res.status(401).json({ error: 'Unauthorized' });
  const token = auth.slice(7);
  jwt.verify(token, jwtSecret, (err, payload) => {
    if (err) return res.status(403).json({ error: 'Invalid token' });
    req.user = payload; // e.g. { userId: 'user1' }
    next();
  });
}

// Create 16-byte session key (base64) and persist
function createSession(userId, slotId, deviceId, callback) {
  const keyBuf = crypto.randomBytes(16); // 128-bit key
  const keyB64 = keyBuf.toString('base64');
  const startTs = Date.now();
  const ttl = 2 * 24 * 3600 * 1000;
  const timeoutId = setTimeout(() => {
    db.run(`DELETE FROM rental_sessions WHERE sessionKey = ?`, [keyB64]);
    db.run(`UPDATE slots SET status = 'available' WHERE id = ?`, [slotId]);
    console.log(`Session expired: ${keyB64}`);
  }, ttl);

  db.run(`INSERT INTO rental_sessions (sessionKey, userId, slotId, deviceId, startTs, returned, overdue, ttlTimeout)
          VALUES (?, ?, ?, ?, ?, 0, 0, ?)`,
    [keyB64, userId, slotId, deviceId, startTs, timeoutId],
    (err) => {
      if (err) return callback(err);
      db.run(`UPDATE slots SET status = 'active' WHERE id = ?`, [slotId], (e) => callback(e, keyB64));
    });
}

// Endpoint: request session (QR scan => server)
app.post('/api/session', authMiddleware, (req, res) => {
  const { slotId, nonce } = req.body;
  const userId = req.user.userId;
  if (!slotId || !nonce) return res.status(400).json({ error: 'Missing fields' });

  db.get(`SELECT 1 FROM used_nonces WHERE nonce = ?`, [nonce], (err, row) => {
    if (err) return res.status(500).json({ error: 'DB error' });
    if (row) return res.status(409).json({ error: 'Nonce already used' });

    db.run(`INSERT INTO used_nonces(nonce) VALUES (?)`, [nonce], (ie) => {
      if (ie) return res.status(500).json({ error: 'DB error' });

      db.get(`SELECT deviceId, status FROM slots WHERE id = ?`, [slotId], (e, slot) => {
        if (e) return res.status(500).json({ error: 'DB error' });
        if (!slot) return res.status(404).json({ error: 'Slot not found' });
        if (slot.status !== 'available') return res.status(409).json({ error: 'Slot not available' });

        createSession(userId, slotId, slot.deviceId, (ce, sessionKeyB64) => {
          if (ce) return res.status(500).json({ error: 'Session creation failed' });
          // Return deviceId and base64 session key
          res.json({ deviceId: slot.deviceId, sessionKey: sessionKeyB64 });
        });
      });
    });
  });
});

// Endpoint: BLE authorize (client asks server if allowed to send command)
app.post('/api/ble/authorize', authMiddleware, (req, res) => {
  const { sessionKey } = req.body;
  if (!sessionKey) return res.status(400).json({ error: 'Missing sessionKey' });
  db.get(`SELECT returned FROM rental_sessions WHERE sessionKey = ?`, [sessionKey], (err, row) => {
    if (err) return res.status(500).json({ error: 'DB error' });
    if (!row || row.returned) return res.status(403).json({ error: 'Invalid session' });
    res.json({ authorized: true });
  });
});

// Endpoint: return (called by app after LOCK received)
app.post('/api/return', authMiddleware, (req, res) => {
  const { sessionKey, location } = req.body;
  if (!sessionKey) return res.status(400).json({ error: 'Missing sessionKey' });

  db.get(`SELECT * FROM rental_sessions WHERE sessionKey = ?`, [sessionKey], (err, session) => {
    if (err) return res.status(500).json({ error: 'DB error' });
    if (!session) return res.status(404).json({ error: 'Session not found or expired' });
    if (session.returned) return res.status(409).json({ error: 'Already returned' });

    const now = Date.now();
    const isOverdue = (now - session.startTs) > 2 * 24 * 3600 * 1000;
    clearTimeout(session.ttlTimeout);
    db.run(`UPDATE rental_sessions SET returned=1, returnTs=?, overdue=? WHERE sessionKey=?`,
      [now, isOverdue ? 1 : 0, sessionKey]);
    db.run(`UPDATE slots SET status='available' WHERE id=?`, [session.slotId]);
    console.log(`Return: ${sessionKey}, overdue: ${isOverdue}, location: ${JSON.stringify(location)}`);
    res.json({ returned: true, overdue: isOverdue });
  });
});

app.use((err, req, res, next) => {
  console.error(err.stack);
  res.status(500).json({ error: 'Server error' });
});

// Quick helper: create a test JWT for user 'testuser'
// console: node -e "console.log(require('jsonwebtoken').sign({userId:'testuser'}, 'YOUR_JWT_SECRET'))"
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => console.log(`Server listening on ${PORT}`));
