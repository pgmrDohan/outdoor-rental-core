#!/usr/bin/env node
// generate-slot.js <slotId> <deviceId>
const sqlite3 = require('sqlite3').verbose();
const path = require('path');
const qrcode = require('qrcode-terminal');

const [,, slotId, deviceId] = process.argv;
if (!slotId || !deviceId) {
  console.error('Usage: node generate-slot.js <slotId> <deviceId>');
  process.exit(1);
}

const nonce = '0x' + Date.now().toString(16);
const payload = { slotId, nonce };
const payloadStr = JSON.stringify(payload);

const dbFile = path.resolve(__dirname, 'server', 'umbrella.db');
const db = new sqlite3.Database(dbFile, (err) => {
  if (err) { console.error('DB open error', err); process.exit(1); }
});

db.run(`INSERT OR REPLACE INTO slots (id, deviceId, status) VALUES (?, ?, 'available')`, [slotId, deviceId], function(err) {
  if (err) { console.error('DB insert error:', err.message); process.exit(1); }
  console.log(`Slot registered: id=${slotId}, deviceId=${deviceId}`);
  console.log('QR Payload:', payloadStr);
  console.log('QR Code:');
  qrcode.generate(payloadStr, { small: true });
  db.close();
});
