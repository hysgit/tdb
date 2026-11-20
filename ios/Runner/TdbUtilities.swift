import Flutter
import CoreFoundation
import UIKit
import UserNotifications

/// Native tools. Registering never asks permission or schedules a notification.
final class TdbUtilities: NSObject, FlutterPlugin, UNUserNotificationCenterDelegate {
  private static let shared = TdbUtilities()
  private static let notificationPrefix = "tdb.utilities."
  private var channel: FlutterMethodChannel?
  private var dartReady = false
  private var pending: [String: Any]?
  private weak var previousNotificationDelegate: UNUserNotificationCenterDelegate?
  private var notificationGeneration: [String: Int] = [:]

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "tingdubao/utilities", binaryMessenger: registrar.messenger())
    shared.channel = channel
    shared.dartReady = false
    registrar.addMethodCallDelegate(shared, channel: channel)
    prepareNotifications()
  }

  /// Call in didFinishLaunching before returning, so cold-launch notification
  /// responses can be buffered even before the implicit Flutter engine exists.
  static func prepareNotifications() {
    let install = {
      let center = UNUserNotificationCenter.current()
      if center.delegate !== shared {
        shared.previousNotificationDelegate = center.delegate
        center.delegate = shared
      }
    }
    if Thread.isMainThread { install() } else { DispatchQueue.main.async(execute: install) }
  }

  /// Deliberately ignores the original app's ASPlay/ASPause/ASUpload schemes.
  static func handleDeepLink(_ url: URL) -> Bool {
    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
          parts.scheme?.lowercased() == "tdb", let host = parts.host?.lowercased(),
          ["play", "pause", "upload"].contains(host),
          parts.path.isEmpty || parts.path == "/",
          parts.user == nil, parts.password == nil, parts.port == nil,
          parts.fragment == nil else { return false }
    let items = parts.queryItems ?? []
    guard items.count <= 1, items.allSatisfy({ $0.name == "mediaId" }) else { return false }
    let mediaId = items.first?.value
    if let mediaId = mediaId,
       (host != "play" || mediaId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || mediaId.count > 512) {
      return false
    }
    receiveAction(type: host, mediaId: mediaId)
    return true
  }

  private static func receiveAction(type: String, mediaId: String?) {
    let deliver = {
      var action: [String: Any] = ["id": UUID().uuidString, "type": type]
      if let mediaId = mediaId { action["mediaId"] = mediaId }
      shared.pending = action
      guard shared.dartReady, let channel = shared.channel else { return }
      let identifier = action["id"] as? String
      channel.invokeMethod("action", arguments: action) { reply in
        // A nil reply acknowledges the Dart handler. Errors/not-implemented keep
        // the last action available to a later pendingAction call.
        if reply == nil && shared.pending?["id"] as? String == identifier {
          shared.pending = nil
        }
      }
    }
    if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    DispatchQueue.main.async { self.handleOnMain(call, result: result) }
  }

  @MainActor
  private func handleOnMain(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "pendingAction":
      dartReady = true
      let action = pending
      pending = nil
      result(action)
    case "lookup":
      guard let word = args["word"] as? String,
            !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            word.count <= 256,
            word.rangeOfCharacter(from: .controlCharacters) == nil else {
        fail(result, "INVALID_ARGUMENT", "请输入有效的查词内容。")
        return
      }
      guard UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: word) else {
        fail(result, "NO_DEFINITION", "本机词典没有该词条，请先下载对应系统词典。")
        return
      }
      guard let presenter = Self.presenter() else {
        fail(result, "NO_UI", "当前没有可显示词典的前台窗口。")
        return
      }
      presenter.present(UIReferenceLibraryViewController(term: word), animated: true) { result(nil) }
    case "share":
      guard let text = args["text"] as? String,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        fail(result, "INVALID_ARGUMENT", "分享内容不能为空。")
        return
      }
      guard let presenter = Self.presenter() else {
        fail(result, "NO_UI", "当前没有可显示分享面板的前台窗口。")
        return
      }
      let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
      if let popover = sheet.popoverPresentationController {
        popover.sourceView = presenter.view
        popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        popover.permittedArrowDirections = []
      }
      sheet.completionWithItemsHandler = { _, completed, _, error in
        DispatchQueue.main.async {
          if let error = error { self.fail(result, "SHARE_FAILED", error.localizedDescription) }
          else { result(completed) }
        }
      }
      presenter.present(sheet, animated: true)
    case "openUrl":
      guard let raw = args["url"] as? String, let url = URL(string: raw),
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else {
        fail(result, "INVALID_ARGUMENT", "仅支持有效的 http 或 https 网页地址。")
        return
      }
      UIApplication.shared.open(url, options: [:]) { opened in
        DispatchQueue.main.async {
          if opened { result(nil) }
          else { self.fail(result, "OPEN_FAILED", "系统未能打开此网页。") }
        }
      }
    case "schedule":
      schedule(args, result: result)
    case "cancelNotification":
      guard let id = Self.notificationId(args["id"]) else {
        fail(result, "INVALID_ARGUMENT", "通知 ID 无效。")
        return
      }
      notificationGeneration[id, default: 0] += 1
      let center = UNUserNotificationCenter.current()
      let identifier = Self.notificationPrefix + id
      center.removePendingNotificationRequests(withIdentifiers: [identifier])
      center.removeDeliveredNotifications(withIdentifiers: [identifier])
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func schedule(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let id = Self.notificationId(args["id"]),
          let title = args["title"] as? String,
          !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let body = args["body"] as? String,
          let milliseconds = args["atMilliseconds"] as? NSNumber,
          CFGetTypeID(milliseconds) != CFBooleanGetTypeID(),
          milliseconds.doubleValue.isFinite else {
      fail(result, "INVALID_ARGUMENT", "通知标题、ID 或时间无效。")
      return
    }
    let date = Date(timeIntervalSince1970: milliseconds.doubleValue / 1000)
    guard date.timeIntervalSinceNow > 0 else {
      fail(result, "INVALID_TIME", "通知时间必须晚于当前时间。")
      return
    }
    var mediaId: String?
    if let raw = args["mediaId"] {
      guard let value = raw as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            value.count <= 512 else {
        fail(result, "INVALID_ARGUMENT", "媒体 ID 无效。")
        return
      }
      mediaId = value
    }
    notificationGeneration[id, default: 0] += 1
    let generation = notificationGeneration[id]!
    let center = UNUserNotificationCenter.current()
    let requestedMediaId = mediaId
    // This is the only permission request, reached only by an explicit schedule.
    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
      DispatchQueue.main.async {
        guard self.notificationGeneration[id] == generation else {
          self.fail(result, "CANCELLED", "通知操作已被取消或替换。")
          return
        }
        if let error = error {
          self.fail(result, "NOTIFICATION_FAILED", error.localizedDescription)
          return
        }
        guard granted else {
          self.fail(result, "PERMISSION_DENIED", "通知权限未开启。")
          return
        }
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else {
          self.fail(result, "INVALID_TIME", "通知时间已过，请重新选择时间。")
          return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let mediaId = requestedMediaId { content.userInfo = ["tdbMediaId": mediaId] }
        let request = UNNotificationRequest(identifier: Self.notificationPrefix + id, content: content,
          trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
        center.add(request) { error in
          DispatchQueue.main.async {
            guard self.notificationGeneration[id] == generation else {
              self.fail(result, "CANCELLED", "通知操作已被取消或替换。")
              return
            }
            if let error = error { self.fail(result, "NOTIFICATION_FAILED", error.localizedDescription) }
            else { result(nil) }
          }
        }
      }
    }
  }

  private static func notificationId(_ raw: Any?) -> String? {
    guard let value = raw as? String else { return nil }
    let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !id.isEmpty && id.count <= 128 && id.rangeOfCharacter(from: .controlCharacters) == nil ? id : nil
  }

  private func fail(_ result: FlutterResult, _ code: String, _ message: String) {
    result(FlutterError(code: code, message: message, details: nil))
  }

  @MainActor
  private static func presenter() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .filter { $0.activationState == .foregroundActive }
    let windows = scenes.flatMap { $0.windows }.filter { !$0.isHidden && $0.windowLevel == .normal }
    guard let root = (windows.first(where: { $0.isKeyWindow }) ?? windows.first)?.rootViewController else { return nil }
    func top(_ controller: UIViewController) -> UIViewController {
      if let presented = controller.presentedViewController, !presented.isBeingDismissed { return top(presented) }
      if let navigation = controller as? UINavigationController, let visible = navigation.visibleViewController { return top(visible) }
      if let tabs = controller as? UITabBarController, let selected = tabs.selectedViewController { return top(selected) }
      return controller
    }
    let controller = top(root)
    guard controller.viewIfLoaded?.window != nil else { return nil }
    return controller.isBeingPresented || controller.isBeingDismissed ? nil : controller
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    if notification.request.identifier.hasPrefix(Self.notificationPrefix) {
      if #available(iOS 14.0, *) { completionHandler([.banner, .sound]) }
      else { completionHandler([.alert, .sound]) }
    } else if let previous = previousNotificationDelegate,
      previous.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))) {
      previous.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
    } else { completionHandler([]) }
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void) {
    if response.notification.request.identifier.hasPrefix(Self.notificationPrefix) {
      if response.actionIdentifier != UNNotificationDismissActionIdentifier,
         let mediaId = response.notification.request.content.userInfo["tdbMediaId"] as? String {
        Self.receiveAction(type: "play", mediaId: mediaId)
      }
      completionHandler()
    } else if let previous = previousNotificationDelegate,
      previous.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))) {
      previous.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
    } else { completionHandler() }
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {
    previousNotificationDelegate?.userNotificationCenter?(center, openSettingsFor: notification)
  }
}
