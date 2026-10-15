import SwiftUI

struct SettingsView: View {
    @AppStorage("pythonPath") private var pythonPath = AppModel.defaultPython
    @AppStorage("repoPath") private var repoPath = AppModel.defaultRepo
    @State private var result: String?
    @State private var failed = false
    @State private var checking = false

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
