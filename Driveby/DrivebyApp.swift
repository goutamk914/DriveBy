//
//  DrivebyApp.swift
//  Driveby
//
//  Created by Goutam Kanakadandi on 10/4/26.
//
//  A coaching app that scores how safely and efficiently you drive, proves the efficiency
//  score against real fuel data, and never records a single thing about anyone else.
//

import SwiftUI

@main
struct DrivebyApp: App {
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
                .task { await model.bootstrap() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.sync.isSignedIn, !model.recorder.isActive {
                Task { await model.sync.syncNow() }
            }
        }
    }
}
