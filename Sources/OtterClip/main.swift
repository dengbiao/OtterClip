import AppKit

MainActor.assumeIsolated {
    if CommandLine.arguments.contains("--self-test") { exit(PlatformChecks.run()) }
    if CommandLine.arguments.contains("--self-test-update-installer") { exit(UpdateInstallerChecks.run()) }
    if CommandLine.arguments.contains("--self-test-updates") {
        Task { exit(await UpdateClientChecks.run()) }
        RunLoop.main.run()
        exit(1)
    }
    UpdateInstaller.beginLaunchIfNeeded()
    let application = NSApplication.shared
    if let index = CommandLine.arguments.firstIndex(of: "--diagnose-paste"), CommandLine.arguments.count > index + 1 {
        let access = PasteController.accessStatus
        let report: [String: Any] = ["accessibility": access.accessibility, "eventPosting": access.eventPosting, "canPaste": access.canPaste, "applicationPath": Bundle.main.bundlePath]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: .atomic)
            exit(0)
        } catch { fputs("Permission diagnosis failed: \(error)\n", stderr); exit(1) }
    }
    if CommandLine.arguments.contains("--self-test-ui") {
        application.setActivationPolicy(.accessory)
        exit(PlatformChecks.runUI())
    }
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
