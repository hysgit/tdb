import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    // Preserve Flutter's engine/window connection. Info.plist disables its
    // automatic route handling; Tdb intents use the buffered native bridge.
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    for context in connectionOptions.urlContexts {
      _ = TdbUtilities.handleDeepLink(context.url)
    }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    let unhandled = Set(URLContexts.filter { !TdbUtilities.handleDeepLink($0.url) })
    if !unhandled.isEmpty { super.scene(scene, openURLContexts: unhandled) }
  }
}
