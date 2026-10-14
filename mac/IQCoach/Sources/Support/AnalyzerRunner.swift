import Foundation

enum AnalyzerError: LocalizedError {
    case pythonMissing(String)
    case repoMissing(String)
    case importFailed(String)
    case failed(Int32, String)
    case noResults(String)

    var errorDescription: String? {
        switch self {
        case .pythonMissing(let p): "No Python interpreter at \(p). Open Settings and point it at the venv's bin/python (for example ~/Developer/iq-analyzer/.venv/bin/python)."
        case .repoMissing(let p): "No iq-analyzer folder at \(p). Open Settings and choose the repository that contains the iqa package."
        case .importFailed(let m): "This Python cannot import iqa. Activate the repo's venv and run pip install -r requirements.txt, then try again. Python said: \(m)"
        case .failed(let code, let tail): "The analyzer stopped with exit code \(code). \(tail)"
        case .noResults(let p): "The analyzer finished but wrote no results.json in \(p)."
        }
    }
}

/// Runs `python -m iqa analyze` as a child process. The app is not sandboxed so it can launch a user-chosen interpreter.
struct AnalyzerRunner: Sendable {
    let python: String
    let repo: String

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    /// Checks the interpreter and repo, returning a human sentence on success.
    func validate() async throws -> String {
        let py = Self.expand(python), repoPath = Self.expand(repo)
        guard FileManager.default.isExecutableFile(atPath: py) else { throw AnalyzerError.pythonMissing(py) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repoPath, isDirectory: &isDir), isDir.boolValue else { throw AnalyzerError.repoMissing(repoPath) }
        let result = try await Self.run(py, ["-c", "import iqa; print(iqa.__file__)"], cwd: repoPath, onLine: { _ in })
        guard result.status == 0 else { throw AnalyzerError.importFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return "Python works and iqa imports from \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))."
    }

    static func runsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("IQCoach/runs", isDirectory: true)
    }

    /// Analyses `folder` and returns the results.json it wrote. `onLine` receives each output line.
    func analyze(folder: URL, onLine: @escaping @Sendable (String) -> Void) async throws -> URL {
        _ = try await validate()
        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.omitted).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let out = Self.runsDirectory().appendingPathComponent(stamp, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let result = try await Self.run(Self.expand(python),
                                        ["-m", "iqa", "analyze", folder.path, "-r", "--out", out.path, "--no-paths"],
                                        cwd: Self.expand(repo), onLine: onLine)
        guard result.status == 0 else {
            throw AnalyzerError.failed(result.status, String(result.output.split(separator: "\n").suffix(3).joined(separator: " ")))
        }
        let json = out.appendingPathComponent("results.json")
        guard FileManager.default.fileExists(atPath: json.path) else { throw AnalyzerError.noResults(out.path) }
        return json
    }

    struct RunResult: Sendable { let status: Int32; let output: String }

    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = ""
        private var all = ""
        func append(_ chunk: String, emit: (String) -> Void) {
            lock.lock(); defer { lock.unlock() }
            all += chunk
            pending += chunk
            while let nl = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                let line = String(pending[..<nl])
                pending = String(pending[pending.index(after: nl)...])
                if !line.isEmpty { emit(line) }
            }
        }
        var text: String { lock.lock(); defer { lock.unlock() }; return all }
    }

    static func run(_ exe: String, _ args: [String], cwd: String, onLine: @escaping @Sendable (String) -> Void) async throws -> RunResult {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            var env = ProcessInfo.processInfo.environment
            env["PYTHONPATH"] = cwd
            env["PYTHONUNBUFFERED"] = "1"
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let buffer = LineBuffer()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                guard !data.isEmpty else { return }
                buffer.append(String(decoding: data, as: UTF8.self), emit: onLine)
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                if !rest.isEmpty { buffer.append(String(decoding: rest, as: UTF8.self) + "\n", emit: onLine) }
                cont.resume(returning: RunResult(status: proc.terminationStatus, output: buffer.text))
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
