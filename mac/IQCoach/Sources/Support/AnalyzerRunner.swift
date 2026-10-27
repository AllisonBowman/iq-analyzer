import Foundation

enum AnalyzerError: LocalizedError {
    case pythonMissing(String)
    case repoMissing(String)
    case importFailed(String)
    case failed(Int32, String)
    case measurementLibrariesMissing(String)
    case noResults(String)

    var errorDescription: String? {
        switch self {
        case .pythonMissing(let p): "No Python interpreter at \(p). Open Settings and point it at the venv's bin/python (for example ~/Developer/iq-analyzer/.venv/bin/python)."
        case .repoMissing(let p): "No iq-analyzer folder at \(p). Open Settings and choose the repository that contains the iqa package."
        case .importFailed(let m): "This Python cannot import iqa and its memory (iqa.memory). Activate the repo's venv, make sure the repository is up to date and run pip install -r requirements.txt, then try again. Python said: \(m)"
        case .failed(let code, let tail): "The analyzer stopped with exit code \(code). \(tail)"
        case .measurementLibrariesMissing(let m): "This Python cannot import the measurement libraries (OpenCV, SciPy, rawpy or pillow-heif), so nothing was measured or marked. Activate the repo's venv and run pip install -r requirements.txt, then try again. Python said: \(m)"
        case .noResults(let p): "The analyzer finished but wrote no results.json in \(p)."
        }
    }
}

/// Runs `python -m iqa analyze` as a child process. The app is not sandboxed so it can launch a user-chosen interpreter.
struct AnalyzerRunner: Sendable {
    let python: String
    let repo: String

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    /// What validation found: the success sentence and the analyzer key the memory stores measurements under.
    struct Check: Sendable, Equatable {
        let sentence: String
        let analyzerKey: String
    }

    /// Checks the interpreter and repo, and reads the current analyzer key (`iqa.memory.analyzer_key()`).
    func validate() async throws -> Check {
        let py = Self.expand(python), repoPath = Self.expand(repo)
        guard FileManager.default.isExecutableFile(atPath: py) else { throw AnalyzerError.pythonMissing(py) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repoPath, isDirectory: &isDir), isDir.boolValue else { throw AnalyzerError.repoMissing(repoPath) }
        let result = try await Self.run(py, ["-c", "import iqa, iqa.memory; print(iqa.__file__); print(iqa.memory.analyzer_key())"],
                                        cwd: repoPath, onLine: { _ in })
        guard result.status == 0, let check = Self.parseCheck(result.output) else {
            throw AnalyzerError.importFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return check
    }

    /// The last two output lines are iqa's file and the analyzer key (anything printed before them is ignored).
    static func parseCheck(_ output: String) -> Check? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count >= 2, let key = lines.last, !key.contains(" ") else { return nil }
        return Check(sentence: "Python works and iqa imports from \(lines[lines.count - 2]).", analyzerKey: key)
    }

    /// `python -m iqa analyze <paths> -r --out <out> --memory <db> [--sources <manifest>] --no-report`. File paths are
    /// kept in results.json (it lives in staging and is deleted with it); the memory records never carry them.
    func analyzeArguments(paths: [URL], out: URL, memory: URL, sources: URL?) -> [String] {
        ["-m", "iqa", "analyze"] + paths.map(\.path) + ["-r", "--out", out.path, "--memory", memory.path]
            + (sources.map { ["--sources", $0.path] } ?? []) + ["--no-report"]
    }

    /// Analyses `paths` into the memory and returns what each photo was (from the IQA-MEMORY lines). `onLine`
    /// receives every other output line. The run holds a user-initiated activity so the Mac does not idle-sleep
    /// under it, and the child runs at utility QoS.
    func analyze(paths: [URL], out: URL, memory: URL, sources: URL?, onLine: @escaping @Sendable (String) -> Void) async throws -> BatchOutcome {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: memory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let collector = OutcomeCollector()
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "Measuring photos with iq-analyzer")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let result = try await Self.run(Self.expand(python), analyzeArguments(paths: paths, out: out, memory: memory, sources: sources),
                                        cwd: Self.expand(repo), qos: .utility) { line in
            if !collector.record(line) { onLine(line) }
        }
        return try Self.finished(status: result.status, output: result.output, outcome: collector.outcome)
    }

    /// `analyze --memory`'s exit codes: 0 a finished run (an empty one included), 4 a finished run in which every
    /// photo failed (each said so in an IQA-MEMORY failed line), 5 the measurement libraries cannot be imported
    /// (nothing marked), 2 usage, 3 the memory, 1 a crash (a signal arrives as 128 + its number). Only 0, and 4 with
    /// its failed lines, are a finished run.
    static func finished(status: Int32, output: String, outcome: BatchOutcome) throws -> BatchOutcome {
        if status == 0 || (status == 4 && outcome.count(.failed) > 0) { return outcome }
        let tail = output.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix(BatchOutcome.prefix) }.suffix(3).joined(separator: " ")
        if status == 5 { throw AnalyzerError.measurementLibrariesMissing(tail) }
        throw AnalyzerError.failed(status, tail)
    }

    /// `python -m iqa memory <args>` (compact, forget), returning its output.
    func memoryCommand(_ args: [String], onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        let result = try await Self.run(Self.expand(python), ["-m", "iqa", "memory"] + args, cwd: Self.expand(repo), qos: .utility, onLine: onLine)
        guard result.status == 0 else {
            throw AnalyzerError.failed(result.status, String(result.output.split(separator: "\n").suffix(3).joined(separator: " ")))
        }
        return result.output
    }

    private final class OutcomeCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var value = BatchOutcome()
        func record(_ line: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return value.record(line)
        }
        var outcome: BatchOutcome { lock.lock(); defer { lock.unlock() }; return value }
    }

    struct RunResult: Sendable { let status: Int32; let output: String }

    /// The exit status, or 128 + the signal for a child killed by one (the shell's convention): SIGILL is 4 and SIGTRAP
    /// 5, so a crash read as a bare status would pass for "every photo failed" or "no measurement libraries".
    static func status(_ reason: Process.TerminationReason, _ status: Int32) -> Int32 {
        reason == .exit ? status : 128 + status
    }

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

    /// Holds the child so cancelling the task stops it (a cancelled run must not keep writing in the background).
    final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        func set(_ p: Process) -> Bool {
            lock.lock(); defer { lock.unlock() }
            process = p
            return !cancelled
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if let p = process, p.isRunning { p.terminate() }
        }
        /// Called once run() has returned: a cancel that came between set() and run() saw no running child to stop.
        func launched() {
            lock.lock(); defer { lock.unlock() }
            if cancelled, let p = process, p.isRunning { p.terminate() }
        }
        var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    static func run(_ exe: String, _ args: [String], cwd: String, qos: QualityOfService = .default,
                    onLine: @escaping @Sendable (String) -> Void) async throws -> RunResult {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.currentDirectoryURL = URL(fileURLWithPath: cwd)
                p.qualityOfService = qos
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
                    if box.wasCancelled {
                        cont.resume(throwing: CancellationError())
                    } else {
                        cont.resume(returning: RunResult(status: Self.status(proc.terminationReason, proc.terminationStatus), output: buffer.text))
                    }
                }
                guard box.set(p) else { cont.resume(throwing: CancellationError()); return }
                do { try p.run(); box.launched() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            box.cancel()
        }
    }
}
