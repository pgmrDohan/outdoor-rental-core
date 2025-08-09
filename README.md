# Outdoor Rental System Core

**Prototype for an outdoor rental/return system** using Arduino (servo lock), Flutter mobile app, and Express backend.
This is a learning-oriented implementation to understand how a shared mobility system can connect a user’s phone to an IoT device for rental/return operations and event logging.

> ⚠ This is a prototype for experimentation — **not production-ready**.

---

## Overview

This project demonstrates a simplified version of the core workflow in a shared mobility service:

**Mobile App (Flutter)** ⟷ **Server (Express)** ⟷ **Edge Device (Arduino with servo lock)**

The mobile app sends rental or return requests to the server.
The server logs the events and sends commands to the Arduino, which operates a servo motor to lock or unlock.

---

## Features

- Rental and return requests from a Flutter app
- Express backend handling API calls and logging sessions/events
- Arduino control of a servo motor to simulate lock/unlock
- Basic state tracking (Available / In Use)
- Event logging for testing and analysis

---

## Architecture

- **Client:** Flutter app (user interface, QR scan or buttons to trigger actions)
- **Server:** Node.js + Express (REST API, log storage in JSON/SQLite)
- **Edge Device:** Arduino Nano 33 BLE Rev.2 with servo motor
- **Data Store:** JSON file or SQLite (for prototype purposes)

---

## Quick Start

### 1. Clone the repository

```bash
git clone https://github.com/pgmrDohan/outdoor-rental-core.git
cd outdoor-rental-core
````

### 2. Create User

```bash
node create_user.js <name> <pw>
node -e "console.log(require('jsonwebtoken').sign({userId:'<id in past line output>'}, 'YOUR_JWT_SECRET'))"
```
Copy&Paste `app/lib/main.dart` on Line 117.

### 3. Start the server

```bash
cd server
npm install
npm start
```

### 4. Upload the Arduino sketch

* Open `arduino/main` folder in Arduino IDE
* Adjust servo pin and communication settings (serial/BLE)
* Upload to your Arduino Nano 33 BLE Rev.2

### 5. Make QR Code
```bash
node generate-slot.js <slot-name> <BLE MAC>
```

### 6. Build APP

```bash
cd app
flutter pub get
flutter run --profile
```
> ⚠ Tested with iOS26 beta on iPhone 11 and had to modify `ios/Runner/AppDelete.swift`

---

## Example Flow

1. User opens the app and sends a **rent** request.
2. Server logs the session and sends an **unlock** command to the Arduino.
3. Servo motor rotates to unlock.
4. On **return**, the app sends a request and the server logs it, then sends a **lock** command.

---

## Limitations

* No authentication, encryption, or payment integration
* Not designed for physical security in real deployments
* No power management or weatherproofing for outdoor use

---

## Possible Improvements

* Replace servo with commercial lock hardware
* Use a cloud database and admin dashboard
* Implement OTA firmware updates
