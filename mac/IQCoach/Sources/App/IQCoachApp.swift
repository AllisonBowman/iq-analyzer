import SwiftUI

struct IQCoachApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .commands { AppCommands(model: model) }

        Window("Glossary", id: "glossary") {
            GlossaryView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 520)
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Results…") { model.isImporting = true }
                .keyboardShortcut("o", modifiers: .command)
            // Not while an analysis is still stopping or the memory is compacted or forgotten.
            Button("Analyze Folder…") { model.isChoosingFolder = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.isBusy)
            Button("Choose Photos to Analyze…") { model.isPickingPhotos = true }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model.isBusy)
        }
        CommandGroup(replacing: .help) {
            Button("Glossary") { openWindow(id: "glossary") }
                .keyboardShortcut("?", modifiers: [.command, .shift])
        }
    }
}
