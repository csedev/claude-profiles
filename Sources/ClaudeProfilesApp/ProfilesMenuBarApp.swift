import AppKit
import ProfileKit
import SwiftUI

@main
struct ProfilesMenuBarApp: App {
    @State private var model = ProfilesModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            // Worst weekly usage across all accounts — the number worth knowing
            // at a glance, because it is the one that ends your week.
            Label(model.headline, systemImage: "person.2.circle")
        }
        .menuBarExtraStyle(.window)
    }

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let model = self.model
        Task { @MainActor in model.start() }
    }
}
