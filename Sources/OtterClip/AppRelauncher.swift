import Foundation

enum AppRelauncher {
    enum RelaunchError: LocalizedError {
        case applicationBundleRequired
        case applicationUnavailable

        var errorDescription: String? {
            switch self {
            case .applicationBundleRequired:
                return "请从已安装的 OtterClip 应用中重启；命令行开发模式不支持此操作。"
            case .applicationUnavailable:
                return "找不到当前应用的可执行文件，请重新安装 OtterClip 后再试。"
            }
        }
    }

    // Positional arguments keep application paths out of the shell program. The
    // bounded wait also prevents a cancelled termination from launching a second app.
    private static let waitForExitScript = """
    attempts=0
    while kill -0 "$1" 2>/dev/null; do
        if [ "$attempts" -ge 300 ]; then
            exit 75
        fi
        /bin/sleep 0.1 || exit 1
        attempts=$((attempts + 1))
    done
    exec /usr/bin/open -a "$2" --args --show-settings
    """

    /// Schedule the replacement before the caller terminates normally. The helper
    /// survives that termination and waits for the old process to fully exit.
    @discardableResult
    static func scheduleRelaunch(
        bundleURL: URL = Bundle.main.bundleURL,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws -> Process {
        let applicationURL = bundleURL.standardizedFileURL
        guard applicationURL.isFileURL, applicationURL.pathExtension.lowercased() == "app" else {
            throw RelaunchError.applicationBundleRequired
        }
        guard let executableURL = Bundle(url: applicationURL)?.executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw RelaunchError.applicationUnavailable
        }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", waitForExitScript, "OtterClip-relaunch", String(processIdentifier), applicationURL.path]
        helper.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        return helper
    }
}
