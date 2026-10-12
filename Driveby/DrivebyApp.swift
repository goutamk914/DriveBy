import SwiftUI

@main
struct DrivebyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(model.settings)
                .environment(model.drives)
                .environment(model.garage)
                .environment(model.practiceLog)
                .environment(model.sync)
                .environment(model.recorder)
                .environment(model.obd)
                .preferredColorScheme(model.settings.appearance.colorScheme)
                .fontDesign(.rounded)
                .task { await model.bootstrap() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.sync.isSignedIn, !model.recorder.isActive {
                Task { await model.sync.syncNow() }
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Typography.styleNavigationBars()
        return true
    }
}
