import Darwin
import Foundation

struct PreparedUpdate: Sendable {
    let stagingDirectory: URL
    let applicationURL: URL
    let destinationURL: URL
}

enum UpdateInstaller {
    enum InstallError: LocalizedError {
        case invalidArchive(String)
        case invalidApplication(String)
        case installedApplicationRequired
        case destinationUnavailable
        case preparationFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidArchive(let reason): return "更新安装包不完整或不安全：\(reason)"
            case .invalidApplication(let reason): return "无法安装此更新：\(reason)"
            case .installedApplicationRequired: return "请先将 OtterClip 拖到可写的应用程序文件夹，再检查更新。"
            case .destinationUnavailable: return "当前应用所在位置不可写，请将 OtterClip 移出磁盘映像，或检查应用程序文件夹的权限。"
            case .preparationFailed(let reason): return "准备更新失败，当前应用未被修改：\(reason)"
            }
        }
    }

    /// The old app is retained until the replacement confirms healthy startup.
    /// Every path is a positional argument; no path is interpolated into code.
    static let installScript = """
    trap '' HUP
    pid="$1"
    stage="$2"
    destination="$3"
    launcher="$4"
    new="$stage/OtterClip.app"
    backup="$stage/Previous.app"
    token="${stage##*.OtterClip-update-}"
    attempts=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$attempts" -ge 300 ]; then
            /bin/rm -rf "$stage"
            exit 75
        fi
        /bin/sleep 0.1 || exit 1
        attempts=$((attempts + 1))
    done
    restore() {
        if [ -e "$backup" ]; then
            if [ -e "$destination" ] || [ -L "$destination" ]; then
                /bin/mv -h "$destination" "$stage/Rejected.app" || return 1
            fi
            /bin/mv -h "$backup" "$destination" || return 1
        fi
        "$launcher" -n -a "$destination" --args --show-settings --update-failed
    }
    if [ ! -d "$destination" ] || [ -L "$destination" ] || [ ! -d "$new" ] || [ -L "$new" ]; then
        "$launcher" -n -a "$destination" --args --show-settings --update-failed
        exit 1
    fi
    /bin/mv -h "$destination" "$backup" || {
        "$launcher" -n -a "$destination" --args --show-settings --update-failed
        exit 1
    }
    if [ -e "$destination" ] || [ -L "$destination" ] || ! /bin/mv -h "$new" "$destination"; then
        restore
        exit 1
    fi
    if ! "$launcher" -n -a "$destination" --args --show-settings --update-token "$token"; then
        restore
        exit 1
    fi
    attempts=0
    while [ "$attempts" -lt 200 ]; do
        if [ -f "$stage/ready" ] && [ -f "$stage/launch-pid" ]; then
            ready=$(/bin/cat "$stage/ready")
            newpid=$(/bin/cat "$stage/launch-pid")
            if [ "$ready" = "$newpid" ]; then
                case "$newpid" in
                    ''|*[!0-9]*) ;;
                    *) if [ "$newpid" -gt 1 ] && kill -0 "$newpid" 2>/dev/null; then /bin/rm -rf "$stage"; exit 0; fi ;;
                esac
            fi
        fi
        /bin/sleep 0.1 || exit 1
        attempts=$((attempts + 1))
    done
    newpid=''
    if [ -f "$stage/launch-pid" ]; then newpid=$(/bin/cat "$stage/launch-pid"); fi
    case "$newpid" in
        ''|*[!0-9]*)
            newpid=$(/bin/ps ax -o pid=,comm= | while read -r candidate executable; do
                if [ "$executable" = "$destination/Contents/MacOS/OtterClip" ]; then printf '%s\\n' "$candidate"; fi
            done)
            if [ -z "$newpid" ]; then restore; exit 1; fi
            case "$newpid" in *[!0-9]*) exit 1 ;; esac
            ;;
    esac
    if [ "$newpid" -le 1 ] || [ "$newpid" = "$pid" ]; then exit 1; fi
    if kill -0 "$newpid" 2>/dev/null; then
        executable=$(/bin/ps -p "$newpid" -o comm=)
        if [ "$executable" != "$destination/Contents/MacOS/OtterClip" ]; then exit 1; fi
        kill -TERM "$newpid" 2>/dev/null || exit 1
        attempts=0
        while kill -0 "$newpid" 2>/dev/null; do
            if [ "$attempts" -ge 100 ]; then exit 1; fi
            /bin/sleep 0.1 || exit 1
            attempts=$((attempts + 1))
        done
    fi
    restore
    exit 1
    """

    static func prepare(
        archiveURL: URL,
        version: String,
        destinationURL: URL = Bundle.main.bundleURL
    ) throws -> PreparedUpdate {
        let destination = try validateDestination(destinationURL)
        try validateArchive(archiveURL)
        let fileManager = FileManager.default
        let unpack = fileManager.temporaryDirectory.appendingPathComponent("OtterClip-unpack-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: unpack, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: unpack) }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".OtterClip-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try run("/usr/bin/unzip", ["-q", archiveURL.path, "-d", unpack.path])
            let unpackedApplication = unpack.appendingPathComponent("OtterClip.app", isDirectory: true)
            try validateApplication(unpackedApplication, version: version)
            // A sibling staging directory guarantees an atomic same-volume rename.
            try fileManager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let stagedApplication = stage.appendingPathComponent("OtterClip.app", isDirectory: true)
            try fileManager.copyItem(at: unpackedApplication, to: stagedApplication)
            try validateApplication(stagedApplication, version: version)
            try Data(destination.path.utf8).write(to: stage.appendingPathComponent("destination-path"), options: .atomic)
            try Data(version.utf8).write(to: stage.appendingPathComponent("expected-version"), options: .atomic)
            return PreparedUpdate(stagingDirectory: stage, applicationURL: stagedApplication, destinationURL: destination)
        } catch {
            try? fileManager.removeItem(at: stage)
            if let error = error as? InstallError { throw error }
            throw InstallError.preparationFailed(error.localizedDescription)
        }
    }

    static func scheduleInstall(
        _ prepared: PreparedUpdate,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws {
        guard processIdentifier > 1 else { throw InstallError.preparationFailed("无法确认当前应用进程。") }
        let destination = try validateDestination(prepared.destinationURL)
        let stage = prepared.stagingDirectory.standardizedFileURL
        let stageAttributes = try? FileManager.default.attributesOfItem(atPath: stage.path)
        guard stage.deletingLastPathComponent() == destination.deletingLastPathComponent(),
              stage.lastPathComponent.hasPrefix(".OtterClip-update-"),
              stage == stage.resolvingSymlinksInPath(),
              (stageAttributes?[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              (stageAttributes?[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              prepared.applicationURL.standardizedFileURL == stage.appendingPathComponent("OtterClip.app", isDirectory: true),
              FileManager.default.fileExists(atPath: prepared.applicationURL.path),
              !FileManager.default.fileExists(atPath: stage.appendingPathComponent("Previous.app").path) else {
            throw InstallError.preparationFailed("更新暂存目录不可用，请重新检查更新。")
        }
        guard let expectedVersion = try? String(contentsOf: stage.appendingPathComponent("expected-version"), encoding: .utf8) else {
            throw InstallError.preparationFailed("更新版本信息不可用，请重新检查更新。")
        }
        try validateApplication(prepared.applicationURL, version: expectedVersion)
        let script = stage.appendingPathComponent("install.sh")
        do {
            try Data(installScript.utf8).write(to: script, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
            helper.arguments = ["/bin/sh", script.path, String(processIdentifier), stage.path, destination.path, "/usr/bin/open"]
            helper.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
            helper.standardInput = FileHandle.nullDevice
            helper.standardOutput = FileHandle.nullDevice
            helper.standardError = FileHandle.nullDevice
            try helper.run()
        } catch {
            throw InstallError.preparationFailed(error.localizedDescription)
        }
    }

    static func discard(_ prepared: PreparedUpdate) {
        let stage = prepared.stagingDirectory.standardizedFileURL
        guard stage.lastPathComponent.hasPrefix(".OtterClip-update-"),
              stage.deletingLastPathComponent() == prepared.destinationURL.standardizedFileURL.deletingLastPathComponent(),
              stage == stage.resolvingSymlinksInPath(),
              !FileManager.default.fileExists(atPath: stage.appendingPathComponent("Previous.app").path) else { return }
        try? FileManager.default.removeItem(at: stage)
    }

    /// The relaunch token names only our own private, adjacent staging directory;
    /// command-line input can never choose a path to write elsewhere.
    static func beginLaunchIfNeeded(arguments: [String] = CommandLine.arguments, bundleURL: URL = Bundle.main.bundleURL) {
        guard let stage = launchStage(arguments: arguments, bundleURL: bundleURL) else { return }
        writeMarker(stage.appendingPathComponent("launch-pid"), contents: String(ProcessInfo.processInfo.processIdentifier))
    }

    static func confirmLaunchIfNeeded(arguments: [String] = CommandLine.arguments, bundleURL: URL = Bundle.main.bundleURL) {
        guard let stage = launchStage(arguments: arguments, bundleURL: bundleURL),
              let launched = try? String(contentsOf: stage.appendingPathComponent("launch-pid"), encoding: .utf8),
              launched == String(ProcessInfo.processInfo.processIdentifier) else { return }
        writeMarker(stage.appendingPathComponent("ready"), contents: launched)
    }

    private static func launchStage(arguments: [String], bundleURL: URL) -> URL? {
        guard let index = arguments.firstIndex(of: "--update-token"), index + 1 < arguments.count else { return nil }
        let token = arguments[index + 1]
        guard UUID(uuidString: token)?.uuidString == token else { return nil }
        let bundle = bundleURL.standardizedFileURL
        guard bundleURL.isFileURL, bundle.pathExtension == "app", bundle == bundle.resolvingSymlinksInPath(),
              Bundle(url: bundle)?.bundleIdentifier == "app.clipshelf.mac" else { return nil }
        let stage = bundle.deletingLastPathComponent().appendingPathComponent(".OtterClip-update-" + token, isDirectory: true)
        guard stage == stage.resolvingSymlinksInPath(),
              let attributes = try? FileManager.default.attributesOfItem(atPath: stage.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              let expected = try? String(contentsOf: stage.appendingPathComponent("destination-path"), encoding: .utf8),
              expected == bundle.path,
              FileManager.default.fileExists(atPath: stage.appendingPathComponent("Previous.app").path) else { return nil }
        return stage
    }

    private static func writeMarker(_ url: URL, contents: String) {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        let bytes = Array(contents.utf8)
        let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, bytes.count) }
        if count != bytes.count { try? FileManager.default.removeItem(at: url) }
    }

    private static func validateDestination(_ url: URL) throws -> URL {
        let destination = url.standardizedFileURL
        let fileManager = FileManager.default
        guard url.isFileURL, destination.pathExtension == "app",
              destination == destination.resolvingSymlinksInPath(),
              let bundle = Bundle(url: destination),
              bundle.bundleIdentifier == "app.clipshelf.mac",
              let executable = bundle.executableURL,
              fileManager.isExecutableFile(atPath: executable.path),
              executable.standardizedFileURL == executable.resolvingSymlinksInPath() else {
            throw InstallError.installedApplicationRequired
        }
        let parent = destination.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: destination.path),
              fileManager.isWritableFile(atPath: parent.path),
              (try? parent.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) != true else {
            throw InstallError.destinationUnavailable
        }
        // Check actual creation permissions before the caller offers to quit.
        let probe = parent.appendingPathComponent(".OtterClip-write-check-\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(at: probe, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try fileManager.removeItem(at: probe)
        } catch { throw InstallError.destinationUnavailable }
        return destination
    }

    private static func validateApplication(_ url: URL, version: String) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw InstallError.invalidApplication("找不到应用内容。")
        }
        for case let entry as URL in enumerator {
            if try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw InstallError.invalidApplication("应用中包含不受支持的符号链接。")
            }
        }
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier == "app.clipshelf.mac" else {
            throw InstallError.invalidApplication("应用身份与 OtterClip 不一致。")
        }
        guard bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else {
            throw InstallError.invalidApplication("应用版本与所选更新不一致。")
        }
        guard let minimum = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String else {
            throw InstallError.invalidApplication("缺少 macOS 版本要求。")
        }
        let parts = minimum.split(separator: ".", omittingEmptySubsequences: false)
        let components = parts.compactMap { Int($0) }
        guard !components.isEmpty, components.count <= 3,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) }),
              components.count == parts.count else {
            throw InstallError.invalidApplication("macOS 版本要求无效。")
        }
        let requiredOS = OperatingSystemVersion(majorVersion: components[0], minorVersion: components.count > 1 ? components[1] : 0, patchVersion: components.count > 2 ? components[2] : 0)
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(requiredOS) else {
            throw InstallError.invalidApplication("此更新需要 macOS \(minimum) 或更新版本。")
        }
        guard let executable = bundle.executableURL,
              executable.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path + "/Contents/MacOS/"),
              fileManager.isExecutableFile(atPath: executable.path) else {
            throw InstallError.invalidApplication("找不到可执行文件。")
        }
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        throw InstallError.invalidApplication("此 Mac 的处理器暂不受支持。")
        #endif
        do { try run("/usr/bin/lipo", [executable.path, "-verify_arch", architecture]) }
        catch { throw InstallError.invalidApplication("此更新不支持当前 Mac 的处理器。") }
        do { try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path]) }
        catch { throw InstallError.invalidApplication("应用签名校验失败，请重新下载更新。") }
    }

    /// Read ZIP metadata before extraction, including UNIX file types. ZIP64,
    /// duplicate names and other ambiguous archive layouts are deliberately refused.
    private static func validateArchive(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= 200 * 1_024 * 1_024 else {
            throw InstallError.invalidArchive("安装包过大。")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        func u16(_ offset: Int) -> Int {
            Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) -> Int {
            u16(offset) | u16(offset + 2) << 16
        }
        func invalid(_ reason: String) -> InstallError { .invalidArchive(reason) }
        guard data.count >= 22 else { throw invalid("ZIP 文件不完整。") }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if u32(offset) == 0x06054b50, offset + 22 + u16(offset + 20) == data.count {
                end = offset
                break
            }
        }
        guard let end, u16(end + 4) == 0, u16(end + 6) == 0,
              u16(end + 8) == u16(end + 10), u16(end + 10) > 0, u16(end + 10) < 65_535 else {
            throw invalid("ZIP 目录无效。")
        }
        let centralSize = u32(end + 12)
        let centralStart = u32(end + 16)
        guard centralStart + centralSize == end else { throw invalid("不支持此 ZIP 格式。") }
        var cursor = centralStart
        var names = Set<String>()
        var expandedSize = 0
        for _ in 0..<u16(end + 10) {
            guard cursor >= 0, cursor + 46 <= end, u32(cursor) == 0x02014b50 else { throw invalid("ZIP 条目无效。") }
            let flags = u16(cursor + 8)
            let method = u16(cursor + 10)
            let compressedSize = u32(cursor + 20)
            let expanded = u32(cursor + 24)
            let nameSize = u16(cursor + 28)
            let extraSize = u16(cursor + 30)
            let commentSize = u16(cursor + 32)
            let localOffset = u32(cursor + 42)
            let next = cursor + 46 + nameSize + extraSize + commentSize
            guard next <= end, flags & 1 == 0, [0, 8].contains(method),
                  compressedSize < 0xffffffff, expanded < 0xffffffff, localOffset < 0xffffffff,
                  u16(cursor + 34) == 0 else { throw invalid("不支持此 ZIP 条目。") }
            let nameBytes = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameSize))
            guard let name = String(data: nameBytes, encoding: .utf8),
                  name.hasPrefix("OtterClip.app/"), !name.contains("\\"), !name.contains(":"),
                  !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw invalid("安装包包含应用目录之外的文件。")
            }
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.contains("."), !parts.contains(".."),
                  !parts.dropLast().contains(""),
                  names.insert(name.trimmingCharacters(in: CharacterSet(charactersIn: "/")).precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw invalid("安装包包含重复或不安全的路径。")
            }
            let type = (u32(cursor + 38) >> 16) & 0xf000
            guard type == 0 || type == 0x8000 || (type == 0x4000 && name.hasSuffix("/")) else {
                throw invalid("安装包包含符号链接或特殊文件。")
            }
            guard localOffset + 30 <= centralStart, u32(localOffset) == 0x04034b50,
                  u16(localOffset + 6) == flags, u16(localOffset + 8) == method else {
                throw invalid("ZIP 文件头不一致。")
            }
            let localNameSize = u16(localOffset + 26)
            let localExtraSize = u16(localOffset + 28)
            let payload = localOffset + 30 + localNameSize + localExtraSize
            guard payload + compressedSize <= centralStart,
                  localNameSize == nameSize,
                  data.subdata(in: (localOffset + 30)..<(localOffset + 30 + localNameSize)) == nameBytes else {
                throw invalid("ZIP 文件路径不一致。")
            }
            expandedSize += expanded
            guard expandedSize <= 500 * 1_024 * 1_024, names.count <= 20_000 else { throw invalid("解压后的安装包过大。") }
            cursor = next
        }
        guard cursor == end else { throw invalid("ZIP 目录长度不一致。") }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw InstallError.preparationFailed("安装包校验或解压失败。") }
    }
}
