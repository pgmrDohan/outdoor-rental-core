// UmbrellaStand_gcm_fixed.ino
// Arduino Nano 33 BLE Rev2 — AES-GCM (mbedTLS) based encrypted commands
// Packet format: [12B nonce] [ciphertext] [16B tag]

#include <ArduinoBLE.h>
#include <ArduinoJson.h>
#include <Servo.h>
#include <string.h>
#include <stdlib.h>

// mbedTLS headers (ensure mbedTLS is available in your build environment)
#include "mbedtls/gcm.h"
#include "mbedtls/aes.h"

// UUIDs
#define SERVICE_UUID               "F26D1039-187E-436F-AC47-8C9DFDF52205"
#define SESSION_CHAR_UUID          "BF82321B-3D15-466A-80C5-A32001C57B01"
#define COMMAND_CHAR_UUID          "900D9B23-28A8-471D-90CC-88839E77D743"
#define STATUS_CHAR_UUID           "7C91093D-46A8-415A-923F-349482D7C818"
#define EPOCH_CHAR_UUID           "502918F2-FF81-44BB-AAB5-C3ACDF0D6E3A"

// BLE objects
BLEService umbrellaService(SERVICE_UUID);
BLECharacteristic sessionChar(SESSION_CHAR_UUID, BLEWrite, 128); // base64 session key
BLECharacteristic commandChar(COMMAND_CHAR_UUID, BLEWrite, 256);
BLECharacteristic statusChar(STATUS_CHAR_UUID, BLENotify, 256);  // notify-capable
BLECharacteristic timeChar(EPOCH_CHAR_UUID, BLEWrite, 8);

// Battery standard service
BLEService batteryService("180F");
BLEUnsignedCharCharacteristic batteryLevelChar("2A19", BLERead | BLENotify);

Servo lockServo;

// AES-GCM context
mbedtls_gcm_context gcm_ctx;
bool gcm_ready = false;
uint8_t sessionKey[16]; // raw 16 bytes
bool sessionActive = false;

int batteryLevel = 100;
String lastNonce = "";

// ===== base64 decode helper (simple) =====
int base64Index(char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+') return 62;
  if (c == '/') return 63;
  return -1;
}

int base64Decode(const char* in, uint8_t* out, int outMax) {
  int len = strlen(in);
  int val = 0, valb = -8;
  int outPos = 0;
  for (int i = 0; i < len; ++i) {
    char c = in[i];
    if (c == '=') break;
    int idx = base64Index(c);
    if (idx < 0) continue;
    val = (val << 6) + idx;
    valb += 6;
    if (valb >= 0) {
      if (outPos < outMax) out[outPos++] = (val >> valb) & 0xFF;
      valb -= 8;
    }
  }
  return outPos;
}

// ===== random bytes (test-only) =====
void randomBytes(uint8_t* buf, int n) {
  for (int i = 0; i < n; ++i) buf[i] = (uint8_t)random(0, 256);
}

// ===== mbedTLS AES-GCM helpers =====
void gcmInitWithKey(const uint8_t key[16]) {
  mbedtls_gcm_init(&gcm_ctx);
  // 128 bits key
  mbedtls_gcm_setkey(&gcm_ctx, MBEDTLS_CIPHER_ID_AES, key, 128);
  gcm_ready = true;
}

// Decrypt packet: packet = [iv(12)] [ciphertext] [tag(16)]
bool aesGcmDecryptPacket(const uint8_t* packet, size_t packetLen, uint8_t* outPlain, size_t* outPlainLen) {
  if (!gcm_ready) return false;
  if (packetLen < 12 + 16) return false;
  const uint8_t* iv = packet;
  const uint8_t* tag = packet + packetLen - 16;
  const uint8_t* cipher = packet + 12;
  size_t cipherLen = packetLen - 12 - 16;

  int ret = mbedtls_gcm_auth_decrypt(&gcm_ctx,
                                    cipherLen,
                                    iv, 12,
                                    NULL, 0,
                                    tag, 16,
                                    cipher,
                                    outPlain);
  if (ret != 0) {
    return false;
  }
  *outPlainLen = cipherLen;
  return true;
}

// Encrypt packet: produce packet = [iv(12)] [ciphertext] [tag(16)]
bool aesGcmEncryptPacket(const uint8_t* plain, size_t plainLen, uint8_t* outPacket, size_t* outPacketLen) {
  if (!gcm_ready) return false;
  uint8_t iv[12];
  randomBytes(iv, 12);
  uint8_t* cipherOut = outPacket + 12;
  uint8_t* tagOut = outPacket + 12 + plainLen;

  int ret = mbedtls_gcm_crypt_and_tag(&gcm_ctx,
                                      MBEDTLS_GCM_ENCRYPT,
                                      plainLen,
                                      iv, 12,
                                      NULL, 0,
                                      plain,
                                      cipherOut,
                                      16, tagOut);
  if (ret != 0) return false;

  memcpy(outPacket, iv, 12);
  *outPacketLen = 12 + plainLen + 16;
  return true;
}

// ===== send encrypted status (packet) =====
void sendEncryptedStatus(const char* status, int bat, int err) {
  DynamicJsonDocument doc(128);
  doc["status"] = status;
  doc["battery"] = bat;
  doc["error_code"] = err;
  String out; serializeJson(doc, out);
  const uint8_t* pt = (const uint8_t*)out.c_str();
  int ptLen = out.length();

  uint8_t packet[512];
  size_t packetLen = 0;
  if (!aesGcmEncryptPacket(pt, ptLen, packet, &packetLen)) {
    Serial.println("Encrypt failed");
    return;
  }

  // send via BLE notify by setValue(buffer, length)
  statusChar.setValue(packet, (int)packetLen);
  // note: ArduinoBLE will send notify to subscribed centrals automatically
  Serial.print("Sent encrypted status: ");
  Serial.println(out);
}

// fallback: send plaintext (debug only)
void sendPlainStatus(const char* status, int bat, int err) {
  DynamicJsonDocument doc(128);
  doc["status"] = status;
  doc["battery"] = bat;
  doc["error_code"] = err;
  String out; serializeJson(doc, out);
  statusChar.setValue(out.c_str()); // setValue(const char*)
  Serial.print("Sent plain status: ");
  Serial.println(out);
}

// ===== BLE callbacks =====
void onSessionWritten(BLEDevice, BLECharacteristic) {
  // read base64 ascii into buffer
  int len = sessionChar.valueLength();
  if (len <= 0 || len > 200) {
    Serial.println("Invalid session value length");
    sendPlainStatus("ERROR", batteryLevel, 5);
    return;
  }
  char buf[256];
  sessionChar.readValue((uint8_t*)buf, len);
  buf[len] = 0; // null-terminate
  Serial.print("Received session (base64): "); Serial.println(buf);

  uint8_t out[32];
  int outLen = base64Decode(buf, out, sizeof(out));
  if (outLen == 16) {
    memcpy(sessionKey, out, 16);
    gcmInitWithKey(sessionKey);
    sessionActive = true;
    lastNonce = "";
    Serial.println("Session key set (16 bytes).");
    sendEncryptedStatus("OK", batteryLevel, 0);
  } else {
    Serial.println("Invalid session key length");
    sendPlainStatus("ERROR", batteryLevel, 5);
  }
}

unsigned long epochOffset = 0;
bool epochSynced = false;

void onTimeWritten(BLEDevice, BLECharacteristic) {
  int len = timeChar.valueLength();
  if (len < 4) {
    Serial.println("time write too short");
    return;
  }
  uint8_t buf[8];
  timeChar.readValue(buf, len);
  // 클라이언트가 little-endian uint32_t epoch을 보낸다고 가정
  uint32_t epoch = (uint32_t)buf[0] | ((uint32_t)buf[1] << 8) | ((uint32_t)buf[2] << 16) | ((uint32_t)buf[3] << 24);
  unsigned long up = millis() / 1000UL;
  epochOffset = epoch - up; // unsigned 연산
  epochSynced = true;
  Serial.print("Time sync received epoch: ");
  Serial.println(epoch);
  Serial.print("epochOffset set to: ");
  Serial.println(epochOffset);
}

void onCommandWritten(BLEDevice, BLECharacteristic) {
  if (!sessionActive) { sendPlainStatus("ERROR", batteryLevel, 4); return; }

  int len = commandChar.valueLength();
  if (len <= 12 + 16) { sendEncryptedStatus("ERROR", batteryLevel, 1); return; }

  uint8_t buf[512];
  commandChar.readValue(buf, len);

  uint8_t plain[512];
  size_t plainLen = 0;
  bool ok = aesGcmDecryptPacket(buf, len, plain, &plainLen);
  if (!ok) {
    Serial.println("Decrypt failed");
    sendEncryptedStatus("ERROR", batteryLevel, 2);
    return;
  }

  // copy plaintext to null-terminated buffer
  int copyLen = plainLen < 511 ? plainLen : 511;
  char jbuf[512];
  memcpy(jbuf, plain, copyLen);
  jbuf[copyLen] = 0;

  Serial.print("Decrypted JSON: "); Serial.println(jbuf);
  DynamicJsonDocument doc(512);
  auto err = deserializeJson(doc, jbuf);
  if (err) {
    sendEncryptedStatus("ERROR", batteryLevel, 3);
    return;
  }

  const char* cmd = doc["command"];
  unsigned long ts = doc["timestamp"] | 0;
  const char* nonce = doc["nonce"] | "";

  unsigned long nowSec = epochSynced ? (epochOffset + (millis() / 1000UL)) : (millis() / 1000UL);
  if (ts > nowSec + 3600UL) { // too-far-future timestamp
    sendEncryptedStatus("ERROR", batteryLevel, 2);
    return;
  }

  String nstr = String(nonce);
  if (nstr.length() && nstr == lastNonce) {
    sendEncryptedStatus("ERROR", batteryLevel, 6); // nonce reuse
    return;
  }
  if (nstr.length()) lastNonce = nstr;

  if (strcmp(cmd, "UNLOCK") == 0) {
    lockServo.write(90);
    sendEncryptedStatus("OK", batteryLevel, 0);
  } else if (strcmp(cmd, "LOCK") == 0) {
    lockServo.write(0);
    sendEncryptedStatus("LOCKED", batteryLevel, 0);
  } else {
    sendEncryptedStatus("ERROR", batteryLevel, 3);
  }
}

void reportBatterySim() {
  batteryLevel--;
  if (batteryLevel < 0) batteryLevel = 100;
  batteryLevelChar.writeValue((uint8_t)batteryLevel);
  Serial.print("Battery Level updated: "); Serial.println(batteryLevel);
}

void macStringToBytes(const String &macStr, uint8_t out[6]) {
  String s = macStr;
  s.replace(":", "");
  s.replace("-", "");
  s.toUpperCase();
  for (int i = 0; i < 6; ++i) {
    String byteHex = s.substring(i*2, i*2 + 2);
    out[i] = (uint8_t) strtoul(byteHex.c_str(), NULL, 16);
  }
}

void setup() {
  Serial.begin(115200);
  while (!Serial);

  randomSeed(analogRead(A0)); // seed PRNG (test only)
  lockServo.attach(2);
  lockServo.write(0);

  if (!BLE.begin()) {
    Serial.println("BLE init failed");
    while (1) delay(1000);
  }

  BLE.setLocalName("UmbrellaStand");

  // Umbrella service
  BLE.setAdvertisedService(umbrellaService);
  umbrellaService.addCharacteristic(sessionChar);
  umbrellaService.addCharacteristic(commandChar);
  umbrellaService.addCharacteristic(statusChar);
  umbrellaService.addCharacteristic(timeChar);
  BLE.addService(umbrellaService);

  String addr = BLE.address(); // e.g. "25:90:38:11:93:A0"
  Serial.print("Local BLE address: "); Serial.println(addr);
  uint8_t macBytes[6] = {0};
  macStringToBytes(addr, macBytes);

  // Manufacturer data format: raw bytes (6 bytes MAC). If you want a company ID prefix,
  // you can prepend two bytes (little-endian) with your Company Identifier (0xFFFF for testing)
  // but many scanners just read raw manufacturer payload.
  BLE.setManufacturerData(macBytes, 6); // <= 핵심: 광고에 6바이트 넣기
  Serial.println("Manufacturer data set to MAC bytes.");

  BLE.addService(umbrellaService);

  // Battery service
  batteryService.addCharacteristic(batteryLevelChar);
  BLE.addService(batteryService);
  batteryLevelChar.writeValue((uint8_t)batteryLevel);

  // callbacks
  sessionChar.setEventHandler(BLEWritten, onSessionWritten);
  commandChar.setEventHandler(BLEWritten, onCommandWritten);
  timeChar.setEventHandler(BLEWritten, onTimeWritten);

  BLE.advertise();
  Serial.println("Advertising...");
}

void loop() {
  BLEDevice central = BLE.central();
  if (central) {
    Serial.print("Connected: "); Serial.println(central.address());
    unsigned long lastReport = millis();
    while (central.connected()) {
      BLE.poll();
      if (millis() - lastReport > 60000) {
        reportBatterySim(); lastReport = millis();
      }
    }
    Serial.println("Disconnected");
    sessionActive = false;
    lastNonce = "";
  }
}
