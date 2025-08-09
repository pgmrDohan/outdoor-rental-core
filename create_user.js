// create_test_user.js
const sqlite3 = require('sqlite3').verbose();
const path = require('path');
const { v4: uuidv4 } = require('uuid');
const bcrypt = require('bcrypt');

const dbFile = path.resolve(__dirname, 'server', 'umbrella.db');
const db = new sqlite3.Database(dbFile);

async function createTestUser(name, plainPassword) {
  const id = uuidv4();
  const saltRounds = 10;
  const passwordHash = await bcrypt.hash(plainPassword, saltRounds);

  db.serialize(() => {
    db.run(
      `INSERT INTO users (id, name, passwordHash) VALUES (?, ?, ?)`,
      [id, name, passwordHash],
      function (err) {
        if (err) {
          console.error('User creation failed:', err.message);
        } else {
          console.log(`User created: id=${id}, name=${name}`);
        }
        db.close();
      }
    );
  });
}

// 예시: node create_test_user.js username password
const [name, password] = process.argv.slice(2);
if (!name || !password) {
  console.error('Usage: node create_test_user.js <username> <password>');
  process.exit(1);
}

createTestUser(name, password);
