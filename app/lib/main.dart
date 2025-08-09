// main.dart (fixed - No Nonce type used)
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:http/http.dart' as http;
import 'package:location/location.dart';
import 'package:cryptography/cryptography.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';
import 'dart:io' show Platform;

class NativePermission {
  static const _chan = MethodChannel('in.dohan.umbrella/permissions');

  // 📷 카버
  static Future<bool> requestCamera() async => _invokeBool('requestCamera');
  static Future<bool> isCameraGranted() async => _invokeBool('isCameraGranted');

  // 📍 일어
  static Future<bool> requestLocationWhenInUse() async => _invokeBool('requestLocationWhenInUse');
  static Future<bool> isLocationWhenInUseGranted() async => _invokeBool('isLocationWhenInUseGranted');

  // 🔵 볼드퐼
  static Future<bool> requestBluetooth() async => _invokeBool('requestBluetooth');
  static Future<bool> isBluetoothGranted() async => _invokeBool('isBluetoothGranted');

  // ⚙️ 앱 설정
  static Future<void> openAppSettings() async {
    try {
      await _chan.invokeMethod('openAppSettings');
    } on PlatformException catch (e) {
      print('cannot open settings: $e');
    }
  }

  // 인도 함범
  static Future<bool> _invokeBool(String method) async {
    try {
      final res = await _chan.invokeMethod(method);
      return res == true;
    } on PlatformException catch (e) {
      print('platform error ($method): $e');
      return false;
    }
  }
}

Future<bool> checkAndRequestPermissions() async {
  // camera + locationWhenInUse 는 iOS/Android 공유로 주르

  // 1) Camera
  if (!await NativePermission.isCameraGranted()) {
    print("기타랑 권리 주르");
    final granted = await NativePermission.requestCamera();
    if (!granted) {
      return false;
    }
  }

  // 2) Location (when in use)
  if (!await NativePermission.isLocationWhenInUseGranted()) {
    print("위치 주르");
    final status = await NativePermission.requestLocationWhenInUse();
    if (!status) return false;
  }

  // 3) Bluetooth: Android 12+ requires BLUETOOTH_SCAN/CONNECT.
  if (Platform.isAndroid) {
    // bluetoothScan (Android)
    if (await Permission.bluetoothScan.isDenied) {
      final s = await Permission.bluetoothScan.request();
      if (!s.isGranted) return false;
    }
    // bluetoothConnect (Android)
    if (await Permission.bluetoothConnect.isDenied) {
      final s = await Permission.bluetoothConnect.request();
      if (!s.isGranted) return false;
    }
  } else if (Platform.isIOS) {
    // iOS: request the generic bluetooth permission (maps to CoreBluetooth)
    if (!await NativePermission.isBluetoothGranted()) {
      final s = await NativePermission.requestBluetooth();
      if (!s) return false;
    }
  }

  // 최소 확인
  final cameraGranted = await NativePermission.isCameraGranted();
  final locationGranted = await NativePermission.isLocationWhenInUseGranted();
  final bluetoothGranted = Platform.isAndroid
      ? (await Permission.bluetoothScan.isGranted && await Permission.bluetoothConnect.isGranted)
      : await NativePermission.isBluetoothGranted();
  return cameraGranted && locationGranted && bluetoothGranted;
}

void main() => runApp(UmbrellaApp());

class UmbrellaApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) => MaterialApp(title: 'Umbrella', home: HomePage());
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final qrKey = GlobalKey(debugLabel: 'QR');
  String? slotId;
  String? nonce;
  String? sessionKeyB64;
  Uint8List? sessionKeyBytes;
  final yourJwtToken = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1c2VySWQiOiJ0ZXN0dXNlciIsImlhdCI6MTc1NDc1NjgwNX0.3yEI5X5ufYhPW_vHCorpeS2TnEciZLSYW7PXrc5j5H4'; // replace with test JWT

  final flutterBle = FlutterReactiveBle();
  StreamSubscription<DiscoveredDevice>? scanSubscription;
  DiscoveredDevice? device;
  late QualifiedCharacteristic sessionKeyChar;
  late QualifiedCharacteristic commandChar;
  late QualifiedCharacteristic statusChar;
  late QualifiedCharacteristic epochChar; // 추가: epoch/time char
  StreamSubscription<ConnectionStateUpdate>? connectionSub;

  bool connected = false;
  String statusText = '';
  int battery = 0;

  // UUIDs (must match Arduino)
  final serviceUuid = Uuid.parse('F26D1039-187E-436F-AC47-8C9DFDF52205');
  final sessionUuid = Uuid.parse('BF82321B-3D15-466A-80C5-A32001C57B01');
  final commandUuid = Uuid.parse('900D9B23-28A8-471D-90CC-88839E77D743');
  final statusUuid  = Uuid.parse('7C91093D-46A8-415A-923F-349482D7C818');
  final epochUuid  = Uuid.parse('502918F2-FF81-44BB-AAB5-C3ACDF0D6E3A'); // 아두이노에 맞춘 UUID

  // AES-GCM algorithm instance
  final AesGcm algorithm = AesGcm.with128bits();

  @override
  void dispose() {
    scanSubscription?.cancel();
    connectionSub?.cancel();
    super.dispose();
  }

	Future<void> scanQRCode() async {
		bool granted = await checkAndRequestPermissions();
		if (!granted) {
			print("권한이 없어서 스캔 불가");
			return;
		}
		final controller = MobileScannerController();

		await Navigator.push(
			context,
			MaterialPageRoute(
				builder: (_) => Scaffold(
					body: MobileScanner(
						controller: controller,
						onDetect: (BarcodeCapture capture) async {
							final List<Barcode> barcodes = capture.barcodes;
							if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
								final scanData = barcodes.first.rawValue!;

								try {
									final data = json.decode(scanData);
									slotId = data['slotId'];
									nonce = data['nonce'];

									await requestSessionKey();

									// Stop scanning and pop
                  controller.dispose();
                  Navigator.pop(context);
									controller.stop();
								} catch (e) {
									debugPrint("Invalid QR code data: $e");
								}
							}
						},
					),
				),
			),
		);
	}

  Future<void> requestSessionKey() async {
    if (slotId == null || nonce == null) return;
    final uri = Uri.parse('http://192.168.1.13:3000/api/session'); // change
    final resp = await http.post(uri,
      headers: {'Content-Type':'application/json','Authorization':'Bearer $yourJwtToken'},
      body: json.encode({'slotId': slotId, 'nonce': nonce}),
    );
    if (resp.statusCode == 200) {
      final body = json.decode(resp.body);
      sessionKeyB64 = body['sessionKey'];
      sessionKeyBytes = Uint8List.fromList(base64.decode(sessionKeyB64!));
      startBleScan(body['deviceId']);
      setState(() => statusText = 'Session received');
    } else {
      setState(() => statusText = 'Session request failed ${resp.statusCode}');
    }
  }

  List<int> _macStringToBytes(String mac) {
    final cleaned = mac.replaceAll(':', '').replaceAll('-', '').toLowerCase();
    final bytes = <int>[];
    for (int i = 0; i < cleaned.length; i += 2) {
      bytes.add(int.parse(cleaned.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }

  bool _containsSubsequence(Uint8List haystack, List<int> needle) {
    if (needle.isEmpty || haystack.length < needle.length) return false;
    for (int i = 0; i <= haystack.length - needle.length; i++) {
      var ok = true;
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) { ok = false; break; }
      }
      if (ok) return true;
    }
    return false;
  }

  void _onFoundDevice(DiscoveredDevice d) {
    // found -> store & connect
    setState(() => device = d);
    scanSubscription?.cancel();
    scanSubscription = null;
    connectToDevice();
  }

  void startBleScan(String deviceIdMac) {
    print('startBleScan $deviceIdMac');
    scanSubscription?.cancel();

    final targetMac = _macStringToBytes(deviceIdMac);
    print('targetMac bytes: $targetMac');

    scanSubscription = flutterBle.scanForDevices(withServices: [serviceUuid]).listen((d) {
      // debug: 코드가 입니다.
      print('scan: id=${d.id} name=${d.name} rssi=${d.rssi} manuf=${d.manufacturerData}');

      // 1) 기존 방법: id가 곳이변다 (Android가 MAC 형을 지배)
      if (d.id.toLowerCase() == deviceIdMac.toLowerCase()) {
        _onFoundDevice(d);
        return;
      }

      // 2) manufacturerData 공유 (대부)
      final Uint8List man = d.manufacturerData;
      if (man.isNotEmpty) {
        // a) manufacturerData 으로 MAC 반수 등록을 추육
        if (_containsSubsequence(man, targetMac)) {
          _onFoundDevice(d);
          return;
        }
        // b) 일부 스캐너/포맷에서 앞 2바이트를 Company ID로 해석하므로,
        //    payload가 (companyId(2) + mac(6)) 형태일 경우 mac이 offset=2에 올 수 있음.
        if (man.length >= 2 + targetMac.length) {
          final sub = man.sublist(2, 2 + targetMac.length);
          var matched = true;
          for (var i = 0; i < targetMac.length; i++) {
            if (sub[i] != targetMac[i]) { matched = false; break; }
          }
          if (matched) {
            _onFoundDevice(d);
            return;
          }
        }
      }

      // (옵션) 이름/서비스 UUID로 fallback 필터링 가능
      // if (d.name != null && d.name!.contains('UmbrellaStand')) { ... }

    }, onError: (e) {
      print('Scan error: $e');
      Future.delayed(Duration(seconds: 1), () => startBleScan(deviceIdMac));
    }, onDone: () {
      print('Scan done');
      Future.delayed(Duration(seconds: 1), () => startBleScan(deviceIdMac));
    });
  }

  void connectToDevice() {
    if (device == null) return;
    connectionSub?.cancel();
    connectionSub = flutterBle.connectToDevice(
      id: device!.id,
      servicesWithCharacteristicsToDiscover: {
        serviceUuid: [sessionUuid, commandUuid, statusUuid, epochUuid]
      }
    ).listen((update) async {
      if (update.connectionState == DeviceConnectionState.connected) {
        sessionKeyChar = QualifiedCharacteristic(serviceId: serviceUuid, characteristicId: sessionUuid, deviceId: device!.id);
        commandChar = QualifiedCharacteristic(serviceId: serviceUuid, characteristicId: commandUuid, deviceId: device!.id);
        statusChar  = QualifiedCharacteristic(serviceId: serviceUuid, characteristicId: statusUuid, deviceId: device!.id);
        epochChar   = QualifiedCharacteristic(serviceId: serviceUuid, characteristicId: epochUuid, deviceId: device!.id);
        setState(() => connected = true);

        // === NEW: write device time (epoch) so Arduino can compute epochOffset ===
        try {
          await writeDeviceTime(device!.id);
          print('Device time written');
        } catch (e) {
          print('Failed to write device time: $e');
        }

        await writeSessionKey();
        subscribeStatus();
      } else if (update.connectionState == DeviceConnectionState.disconnected) {
        setState(() {
          connected = false;
          statusText = 'Disconnected';
        });
      }
    }, onError: (e) {
      print('Connect error: $e');
      setState(() => statusText = 'Connect error');
    });
  }

  Future<void> writeSessionKey() async {
    if (sessionKeyB64 == null) return;
    await flutterBle.writeCharacteristicWithResponse(sessionKeyChar, value: utf8.encode(sessionKeyB64!));
    setState(() => statusText = 'Session key sent');
  }

  void subscribeStatus() {
    flutterBle.subscribeToCharacteristic(statusChar).listen((data) async {
      if (sessionKeyBytes == null) return;
      final packet = Uint8List.fromList(data);
      final plain = await decryptAesGcm(sessionKeyBytes!, packet);
      if (plain == null) {
        print('Failed to decrypt status');
        return;
      }
      final jsonStr = utf8.decode(plain);
      final m = json.decode(jsonStr);
      setState(() {
        statusText = m['status'];
        battery = m['battery'];
      });
      if (m['status'] == 'LOCKED') reportReturn();
    }, onError: (e) {
      print('Status subscribe error: $e');
    });
  }

  Future<void> reportReturn() async {
    final loc = await Location().getLocation();
    final uri = Uri.parse('http://192.168.1.13:3000/api/return');
    await http.post(uri,
      headers: {'Content-Type':'application/json','Authorization':'Bearer $yourJwtToken'},
      body: json.encode({'sessionKey': sessionKeyB64, 'location': {'lat': loc.latitude, 'lng': loc.longitude}}));
  }

  Future<bool> authorizeBleCommand() async {
    final uri = Uri.parse('http://192.168.1.13:3000/api/ble/authorize');
    final resp = await http.post(uri,
      headers: {'Content-Type':'application/json','Authorization':'Bearer $yourJwtToken'},
      body: json.encode({'sessionKey': sessionKeyB64}));
    if (resp.statusCode != 200) return false;
    final body = json.decode(resp.body);
    return body['authorized'] == true;
  }

  // --- AES-GCM helpers (cryptography) ---
  Future<Uint8List> encryptAesGcm(Uint8List key, Uint8List plaintext) async {
    final secretKey = SecretKey(key);
    final List<int> nonceBytes = algorithm.newNonce();
    final secretBox = await algorithm.encrypt(plaintext, secretKey: secretKey, nonce: nonceBytes);
    final out = <int>[];
    out.addAll(nonceBytes);
    out.addAll(secretBox.cipherText);
    out.addAll(secretBox.mac.bytes);
    return Uint8List.fromList(out);
  }

  Future<Uint8List?> decryptAesGcm(Uint8List key, Uint8List packet) async {
    if (packet.length < 12 + 16 + 1) return null;
    final nonceBytes = packet.sublist(0, 12);
    final macBytes = packet.sublist(packet.length - 16);
    final cipherBytes = packet.sublist(12, packet.length - 16);
    final secretKey = SecretKey(key);
    try {
      final secretBox = SecretBox(cipherBytes, nonce: nonceBytes, mac: Mac(macBytes));
      final plain = await algorithm.decrypt(secretBox, secretKey: secretKey);
      return Uint8List.fromList(plain);
    } catch (e) {
      print('decrypt failed: $e');
      return null;
    }
  }

  Future<void> sendCommandEncrypted(String cmd) async {
    if (!connected) return;
    if (!await authorizeBleCommand()) {
      setState(() => statusText = 'Not authorized');
      return;
    }
    if (sessionKeyBytes == null) { setState(() => statusText = 'No session key'); return; }
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final jsonStr = json.encode({'command': cmd, 'timestamp': ts, 'nonce': '0x${ts.toRadixString(16)}'});
    final plain = Uint8List.fromList(utf8.encode(jsonStr));
    final packet = await encryptAesGcm(sessionKeyBytes!, plain);
    await flutterBle.writeCharacteristicWithResponse(commandChar, value: packet);
  }

  // === NEW: write epoch (4-byte little-endian) to device ===
  Uint8List _epochToBytesLittleEndian(int epochSec) {
    final b = ByteData(4);
    b.setUint32(0, epochSec, Endian.little);
    return b.buffer.asUint8List();
  }

  Future<void> writeDeviceTime(String deviceId) async {
    final epochSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final bytes = _epochToBytesLittleEndian(epochSec);
    final qc = QualifiedCharacteristic(serviceId: serviceUuid, characteristicId: epochUuid, deviceId: deviceId);
    await flutterBle.writeCharacteristicWithResponse(qc, value: bytes);
    print('Wrote epoch $epochSec to device $deviceId');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Umbrella Stand Test')),
      body: Padding(padding: EdgeInsets.all(16), child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ElevatedButton(onPressed: scanQRCode, child: Text('Scan QR Code')),
          if (slotId != null) Text('Slot: $slotId'),
          if (device != null) Text('Device: ${device!.name} / ${device!.id}'),
          ElevatedButton(onPressed: connectToDevice, child: Text(connected ? 'Connected' : 'Connect BLE')),
				Text('Status: $statusText'),
          if (connected) ...[
            ElevatedButton(onPressed: () => sendCommandEncrypted('UNLOCK'), child: Text('UNLOCK')),
            ElevatedButton(onPressed: () => sendCommandEncrypted('LOCK'), child: Text('LOCK')),
            SizedBox(height: 10),
            Text('Battery: $battery%'),
          ],
        ],
      )),
    );
  }
}