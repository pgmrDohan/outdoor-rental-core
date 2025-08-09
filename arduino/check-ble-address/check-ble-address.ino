#include <ArduinoBLE.h>

void setup() {
  Serial.begin(115200);
  while (!Serial);

  if (!BLE.begin()) {
    Serial.println("BLE init failed!");
    while (1);
  }

  // 광고 시작 전 MAC 주소 출력
  Serial.print("Local BLE Address: ");
  Serial.println(BLE.address());   // Nano 33 BLE Rev2의 MAC

  // 나머지 서비스/특성 초기화…
  BLE.advertise();
}

void loop() {
  // ...
}
