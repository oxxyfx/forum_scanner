import Flutter
import UIKit
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Register the periodic background sync task (must match the
    // identifier in Info.plist's BGTaskSchedulerPermittedIdentifiers and
    // the taskName passed to Workmanager().registerPeriodicTask in Dart).
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: "com.example.nghobbies.forum_scanner.sync",
      frequency: NSNumber(value: 20 * 60)
    )

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
