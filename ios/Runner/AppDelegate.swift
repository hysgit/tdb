import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    TdbUtilities.prepareNotifications()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ application: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if TdbUtilities.handleDeepLink(url) { return true }
    return super.application(application, open: url, options: options)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "TdbUtilities") {
      TdbUtilities.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "TdbAudioTools") {
      TdbAudioTools.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "TdbSpeechBridge") {
      TdbSpeechBridge.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "TdbTransfer") {
      let plugin = TdbTransfer()
      let channel = FlutterMethodChannel(name: "tingdubao/transfer", binaryMessenger: registrar.messenger())
      registrar.addMethodCallDelegate(plugin, channel: channel)
    }
  }
}

private class TdbTransfer: NSObject, FlutterPlugin {
  private var previousIdleState: Bool?

  static func register(with registrar: FlutterPluginRegistrar) {}

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "setActive", let active = call.arguments as? Bool else {
      result(FlutterMethodNotImplemented)
      return
    }
    DispatchQueue.main.async {
      if active {
        if self.previousIdleState == nil {
          self.previousIdleState = UIApplication.shared.isIdleTimerDisabled
        }
        UIApplication.shared.isIdleTimerDisabled = true
      } else if let previous = self.previousIdleState {
        UIApplication.shared.isIdleTimerDisabled = previous
        self.previousIdleState = nil
      }
      result(nil)
    }
  }
}
