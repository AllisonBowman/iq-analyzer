import SwiftUI
import AppKit

// `IQCoach --snapshot <results.json> <outdir>` renders PNGs and exits; otherwise run the app.
let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--snapshot"), arguments.count > i + 2 {
    let input = arguments[i + 1], outdir = arguments[i + 2]
    let code: Int32 = MainActor.assumeIsolated { SnapshotRunner.run(input: input, outputDirectory: outdir) }
    exit(code)
} else {
    // `IQCoach --window-shots <results.json> <outdir>` runs the real app, captures its window and exits.
    if let i = arguments.firstIndex(of: "--window-shots"), arguments.count > i + 2 {
        WindowShots.request = (arguments[i + 1], arguments[i + 2])
    }
    // `IQCoach --analyze-photos 40` starts the Photos import and analysis as soon as the window opens.
    if let i = arguments.firstIndex(of: "--analyze-photos"), arguments.count > i + 1, let n = Int(arguments[i + 1]) {
        LaunchOptions.analyzePhotosCount = n
    }
    IQCoachApp.main()
}

enum LaunchOptions {
    nonisolated(unsafe) static var analyzePhotosCount: Int?
}
