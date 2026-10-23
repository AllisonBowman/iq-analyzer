import SwiftUI

struct SettingsView: View {
    @AppStorage("pythonPath") private var pythonPath = AppModel.defaultPython
    @AppStorage("repoPath") private var repoPath = AppModel.defaultRepo
    @State private var result: String?
    @State private var failed = false
    @State private var checking = false
    @State private var confirmingReset = false
    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        Form {
            Section {
                TextField("Python interpreter", text: $pythonPath, prompt: Text(AppModel.defaultPython))
                    .help("The python inside the iq-analyzer virtual environment")
                TextField("iq-analyzer folder", text: $repoPath, prompt: Text(AppModel.defaultRepo))
                    .help("The repository folder that contains the iqa package")
            } footer: {
                Text("Analyze Folder runs python -m iqa analyze with this interpreter. Create the environment with python3 -m venv .venv and pip install -r requirements.txt in the repository.")
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Validate") { validate() }.disabled(checking)
                    if checking { ProgressView().controlSize(.small) }
                }
                if let result {
                    Label(result, systemImage: failed ? "xmark.octagon" : "checkmark.circle")
                        .foregroundStyle(failed ? Color.red : Color.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let store = model?.preferences {
                Section {
                    Button("Reset Preferences…") { confirmingReset = true }
                        .confirmationDialog("Reset preferences?", isPresented: $confirmingReset) {
                            Button("Reset Preferences", role: .destructive) { store.reset() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This brings back every card you set aside, removes every intent tag on your photos and ends every check. The results files are not touched.")
                        }
                    if let bad = store.movedAside {
                        Label("A damaged preferences file was moved aside as \(bad.lastPathComponent).", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Your choices")
                } footer: {
                    Text("Set-aside cards, intent tags, the editor and checks are kept in \(store.fileURL.path).")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func validate() {
        checking = true
        let runner = AnalyzerRunner(python: pythonPath, repo: repoPath)
        Task {
            do {
                result = try await runner.validate()
                failed = false
            } catch {
                result = error.localizedDescription
                failed = true
            }
            checking = false
        }
    }
}
