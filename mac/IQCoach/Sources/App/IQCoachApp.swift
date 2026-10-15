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
                .frame(minWidth: 760, minHeight: 520)
        }

        Settings {
            SettingsView()
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
            Button("Analyze Folder…") { model.isChoosingFolder = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Analyze \(AppModel.photosCount) Newest from Photos") { model.analyzeFromPhotos(count: AppModel.photosCount) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .help) {
            Button("Glossary") { openWindow(id: "glossary") }
                .keyboardShortcut("?", modifiers: [.command, .shift])
        }
    }
}
