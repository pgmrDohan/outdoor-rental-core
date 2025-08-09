import UIKit
import Flutter
import AVFoundation
import CoreLocation
import CoreBluetooth

@main
@objc class AppDelegate: FlutterAppDelegate, CBCentralManagerDelegate {

  var locationManager: CLLocationManager?
  var bluetoothManager: CBCentralManager?
  var bluetoothRequestResult: FlutterResult?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    guard let controller = window?.rootViewController as? FlutterViewController else {
      print("❗️rootViewController is not FlutterViewController")
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    let channel = FlutterMethodChannel(
      name: "in.dohan.umbrella/permissions",
      binaryMessenger: controller.binaryMessenger
    )

    channel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
      switch call.method {

      // 카메라 권한 요청
      case "requestCamera":
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .notDetermined:
          AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { result(granted) }
          }
        case .authorized:
          result(true)
        default:
          result(false)
        }

      // 카메라 권한 상태 확인
      case "isCameraGranted":
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        result(status == .authorized)

      // 위치 권한 요청
      case "requestLocationWhenInUse":
        let status = CLLocationManager.authorizationStatus()
        if status == .notDetermined {
          self.locationManager = CLLocationManager()
          self.locationManager?.requestWhenInUseAuthorization()
          result(nil)
        } else {
          result(status == .authorizedWhenInUse || status == .authorizedAlways)
        }

      // 위치 권한 상태 확인
      case "isLocationWhenInUseGranted":
        let status = CLLocationManager.authorizationStatus()
        result(status == .authorizedWhenInUse || status == .authorizedAlways)

      // 블루투스 권한 요청
      case "requestBluetooth":
        if #available(iOS 13.0, *) {
          let auth = CBManager.authorization
          if auth == .notDetermined {
            self.bluetoothRequestResult = result
            self.bluetoothManager = CBCentralManager(delegate: self, queue: nil)
          } else {
            result(auth == .allowedAlways)
          }
        } else {
          let auth = CBPeripheralManager.authorizationStatus()
          result(auth == .authorized)
        }

      // 블루투스 권한 상태 확인
      case "isBluetoothGranted":
        if #available(iOS 13.0, *) {
          result(CBManager.authorization == .allowedAlways)
        } else {
          result(CBPeripheralManager.authorizationStatus() == .authorized)
        }

      // 앱 설정 열기
      case "openAppSettings":
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url, options: [:], completionHandler: nil)
          result(nil)
        } else {
          result(FlutterError(code: "NO_URL", message: nil, details: nil))
        }

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    print("✅ Permission channel registered")
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // CBCentralManagerDelegate - 블루투스 상태 변화
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if let result = bluetoothRequestResult {
      if #available(iOS 13.0, *) {
        result(CBManager.authorization == .allowedAlways)
      } else {
        result(CBPeripheralManager.authorizationStatus() == .authorized)
      }
      bluetoothRequestResult = nil
    }
  }
}