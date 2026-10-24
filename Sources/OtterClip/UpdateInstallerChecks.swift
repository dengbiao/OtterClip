import Darwin
import Foundation

/// Installer checks use only signed throwaway bundles and a fake launcher. They
/// never replace the installed app, launch an app, or inspect clipboard history.
enum UpdateInstallerChecks {
    static func run() -> Int32 {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("OtterClip Installer ' $ ` 测试-\(UUID().uuidString)", isDirectory: true)
        var passed = 0
        var failed = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            if condition() { passed += 1; print("PASS: \(name)") }
            else { failed += 1; print("FAIL: \(name)") }
        }
        func rejects(_ name: String, _ operation: () throws -> Void) {
            do { try operation(); check(false, name) }
            catch { check(true, name) }
        }
        func rejectsArchive(_ name: String, _ operation: () throws -> Void) {
            do { try operation(); check(false, name) }
            catch UpdateInstaller.InstallError.invalidArchive { check(true, name) }
            catch { check(false, "\(name) (must reject before extraction)") }
        }
        func rejectsApplication(_ name: String, _ operation: () throws -> Void) {
            do { try operation(); check(false, name) }
            catch UpdateInstaller.InstallError.invalidApplication { check(true, name) }
            catch { check(false, "\(name) (must reject application validation)") }
        }
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fileManager.removeItem(at: root) }
            func process(_ executable: String, _ arguments: [String], at directory: URL? = nil) throws -> Process {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: executable)
                task.arguments = arguments
                task.currentDirectoryURL = directory
                task.standardInput = FileHandle.nullDevice
                task.standardOutput = FileHandle.nullDevice
                task.standardError = FileHandle.nullDevice
                try task.run()
                return task
            }
            func command(_ executable: String, _ arguments: [String], at directory: URL? = nil) throws {
                let task = try process(executable, arguments, at: directory)
                task.waitUntilExit()
                if task.terminationStatus != 0 { throw NSError(domain: "InstallerFixture", code: Int(task.terminationStatus)) }
            }
            let fixtureSource = root.appendingPathComponent("fixture.swift")
            let fixtureExecutable = root.appendingPathComponent("fixture-executable")
            try Data("import Darwin\nsleep(30)\n".utf8).write(to: fixtureSource)
            try command("/usr/bin/xcrun", ["swiftc", fixtureSource.path, "-o", fixtureExecutable.path])
            func fixture(_ name: String, version: String = "9.8.7", identity: String = "app.clipshelf.mac", minimumOS: String = "13.0", signed: Bool = true) throws -> URL {
                let directory = root.appendingPathComponent(name, isDirectory: true)
                let app = directory.appendingPathComponent("OtterClip.app", isDirectory: true)
                let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
                try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
                let plist: [String: Any] = [
                    "CFBundleIdentifier": identity,
                    "CFBundleName": "OtterClip",
                    "CFBundleExecutable": "OtterClip",
                    "CFBundlePackageType": "APPL",
                    "CFBundleVersion": "1",
                    "CFBundleShortVersionString": version,
                    "LSMinimumSystemVersion": minimumOS
                ]
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                    .write(to: app.appendingPathComponent("Contents/Info.plist"))
                try fileManager.copyItem(at: fixtureExecutable, to: macOS.appendingPathComponent("OtterClip"))
                if signed { try command("/usr/bin/codesign", ["--force", "--sign", "-", app.path]) }
                else { try command("/usr/bin/codesign", ["--remove-signature", macOS.appendingPathComponent("OtterClip").path]) }
                return app
            }
            func archive(_ app: URL) throws -> URL {
                let zip = app.deletingLastPathComponent().appendingPathComponent("update.zip")
                try command("/usr/bin/ditto", ["--norsrc", "--noextattr", "-c", "-k", "--keepParent", app.path, zip.path])
                return zip
            }
            let installed = try fixture("Installed app ' $ ` 中文", version: "9.8.6")
            let oldInfo = try Data(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))
            let candidate = try fixture("Candidate")
            let candidateZip = try archive(candidate)
            let prepared = try UpdateInstaller.prepare(archiveURL: candidateZip, version: "9.8.7", destinationURL: installed)
            check(fileManager.fileExists(atPath: prepared.applicationURL.path), "valid signed update prepared")
            check(prepared.stagingDirectory.deletingLastPathComponent() == installed.deletingLastPathComponent(), "staging remains on destination volume")
            check((try? fileManager.attributesOfItem(atPath: prepared.stagingDirectory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700, "staging directory is private")
            check((try? Data(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))) == oldInfo, "preparation does not change installed application")
            UpdateInstaller.discard(prepared)
            check(!fileManager.fileExists(atPath: prepared.stagingDirectory.path), "discard removes only prepared files")
            rejectsApplication("version mismatch rejected") { _ = try UpdateInstaller.prepare(archiveURL: candidateZip, version: "9.8.8", destinationURL: installed) }
            for (name, app) in [
                ("identity mismatch rejected", try fixture("Wrong identity", identity: "com.example.other")),
                ("incompatible macOS rejected", try fixture("Future macOS", minimumOS: "999.0")),
                ("malformed macOS requirement rejected", try fixture("Malformed macOS", minimumOS: "13..0")),
                ("missing signature rejected", try fixture("Unsigned", signed: false))
            ] {
                let zip = try archive(app)
                rejectsApplication(name) { _ = try UpdateInstaller.prepare(archiveURL: zip, version: "9.8.7", destinationURL: installed) }
            }
            let tampered = try fixture("Tampered")
            let tamperedExecutable = try FileHandle(forWritingTo: tampered.appendingPathComponent("Contents/MacOS/OtterClip"))
            try tamperedExecutable.seekToEnd()
            try tamperedExecutable.write(contentsOf: Data(repeating: 0, count: 64))
            try tamperedExecutable.close()
            let tamperedZip = try archive(tampered)
            rejectsApplication("tampered signature rejected") { _ = try UpdateInstaller.prepare(archiveURL: tamperedZip, version: "9.8.7", destinationURL: installed) }
            let nonMachO = try fixture("Not MachO")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: nonMachO.appendingPathComponent("Contents/MacOS/OtterClip"))
            let nonMachOZip = try archive(nonMachO)
            rejectsApplication("non-Mach-O executable rejected") { _ = try UpdateInstaller.prepare(archiveURL: nonMachOZip, version: "9.8.7", destinationURL: installed) }
            let linkTarget = root.appendingPathComponent("Symlink.app")
            try fileManager.createSymbolicLink(at: linkTarget, withDestinationURL: installed)
            rejects("symlink installation target rejected") { _ = try UpdateInstaller.prepare(archiveURL: candidateZip, version: "9.8.7", destinationURL: linkTarget) }
            rejects("bare executable installation target rejected") { _ = try UpdateInstaller.prepare(archiveURL: candidateZip, version: "9.8.7", destinationURL: installed.appendingPathComponent("Contents/MacOS/OtterClip")) }
            let installedParent = installed.deletingLastPathComponent()
            try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: installedParent.path)
            rejects("read-only installation directory rejected") { _ = try UpdateInstaller.prepare(archiveURL: candidateZip, version: "9.8.7", destinationURL: installed) }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installedParent.path)

            // Build structurally valid hostile ZIP fixtures without extracting them.
            func zipFixture(_ name: String, entries: [(String, UInt32)]) throws -> URL {
                var data = Data(), directory = Data()
                func append16(_ value: Int, to bytes: inout Data) {
                    bytes.append(UInt8(truncatingIfNeeded: value)); bytes.append(UInt8(truncatingIfNeeded: value >> 8))
                }
                func append32(_ value: Int, to bytes: inout Data) {
                    append16(value, to: &bytes); append16(value >> 16, to: &bytes)
                }
                for (path, attributes) in entries {
                    let filename = Data(path.utf8), offset = data.count
                    append32(0x04034b50, to: &data)
                    for value in [20, 0, 0, 0, 0] { append16(value, to: &data) }
                    for _ in 0..<3 { append32(0, to: &data) }
                    append16(filename.count, to: &data); append16(0, to: &data); data.append(filename)
                    append32(0x02014b50, to: &directory)
                    for value in [0x0314, 20, 0, 0, 0, 0] { append16(value, to: &directory) }
                    for _ in 0..<3 { append32(0, to: &directory) }
                    for value in [filename.count, 0, 0, 0, 0] { append16(value, to: &directory) }
                    append32(Int(attributes), to: &directory); append32(offset, to: &directory); directory.append(filename)
                }
                let start = data.count
                data.append(directory)
                append32(0x06054b50, to: &data)
                for value in [0, 0, entries.count, entries.count] { append16(value, to: &data) }
                append32(directory.count, to: &data); append32(start, to: &data); append16(0, to: &data)
                let url = root.appendingPathComponent(name + ".zip")
                try data.write(to: url)
                return url
            }
            let regular: UInt32 = 0x81a40000
            for (name, entries) in [
                ("archive symlink rejected", [("OtterClip.app/Contents/link", UInt32(0xa1ff0000))]),
                ("archive traversal rejected", [("OtterClip.app/../../outside", regular)]),
                ("archive absolute path rejected", [("/OtterClip.app/Contents/a", regular)]),
                ("archive sibling file rejected", [("Outside.txt", regular)]),
                ("archive duplicate path rejected", [("OtterClip.app/a", regular), ("OtterClip.app/a", regular)]),
                ("archive case collision rejected", [("OtterClip.app/a", regular), ("OtterClip.app/A", regular)])
            ] {
                let zip = try zipFixture(name, entries: entries)
                rejectsArchive(name) { _ = try UpdateInstaller.prepare(archiveURL: zip, version: "9.8.7", destinationURL: installed) }
            }
            let launcher = root.appendingPathComponent("fake launcher ' $ ` 中文.sh")
            let launchLog = root.appendingPathComponent("launch.log")
            // The fake launcher records argument boundaries and fails the first
            // launch when requested, allowing the real script's rollback to run.
            let launcherScript = """
            #!/bin/sh
            printf '%s\\n' "$@" >> "$(/usr/bin/dirname "$0")/launch.log"
            if [ -f "$(/usr/bin/dirname "$0")/fail-first" ] && [ "$6" != "--update-failed" ]; then
                exit 1
            fi
            if [ "$6" = "--update-token" ]; then
                stage="$(/usr/bin/dirname "$3")/.OtterClip-update-$7"
                if [ ! -f "$(/usr/bin/dirname "$0")/no-pid" ]; then
                    "$3/Contents/MacOS/OtterClip" &
                    child="$!"
                    printf '%s' "$child" > "$(/usr/bin/dirname "$0")/child-pid"
                    printf '%s' "$child" > "$stage/launch-pid"
                    if [ ! -f "$(/usr/bin/dirname "$0")/no-ready" ]; then
                        printf '%s' "$child" > "$stage/ready"
                    fi
                elif [ -f "$(/usr/bin/dirname "$0")/unregistered-process" ]; then
                    "$3/Contents/MacOS/OtterClip" &
                    printf '%s' "$!" > "$(/usr/bin/dirname "$0")/child-pid"
                fi
            fi
            exit 0
            """
            try Data(launcherScript.utf8).write(to: launcher)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
            func runScript(_ prepared: PreparedUpdate, pid: Int32, shorterTimeout: Bool = false) throws -> Process {
                let script = shorterTimeout ? UpdateInstaller.installScript.replacingOccurrences(of: "-ge 300", with: "-ge 3") : UpdateInstaller.installScript
                return try process("/bin/sh", ["-c", script, "OtterClip installer fixture", String(pid), prepared.stagingDirectory.path, prepared.destinationURL.path, launcher.path])
            }
            let sleeper = try process("/bin/sleep", ["30"])
            defer { if sleeper.isRunning { sleeper.terminate(); sleeper.waitUntilExit() } }
            let blocked = try UpdateInstaller.prepare(archiveURL: candidateZip, version: "9.8.7", destinationURL: installed)
            let timedOut = try runScript(blocked, pid: sleeper.processIdentifier, shorterTimeout: true)
            timedOut.waitUntilExit()
            check(timedOut.terminationStatus == 75, "cancelled termination reaches bounded helper timeout")
            check((try? Data(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))) == oldInfo, "live original process prevents application replacement")
            check(!fileManager.fileExists(atPath: launchLog.path), "timeout does not launch a second application")

            let success = try UpdateInstaller.prepare(archiveURL: candidateZip, version: "9.8.7", destinationURL: installed)
            let updater = try runScript(success, pid: sleeper.processIdentifier)
            Thread.sleep(forTimeInterval: 0.15)
            check(fileManager.fileExists(atPath: success.applicationURL.path), "helper waits without moving prepared application")
            sleeper.terminate(); sleeper.waitUntilExit()
            updater.waitUntilExit()
            check(updater.terminationStatus == 0, "exited original process permits replacement")
            check((try? Data(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))) == (try? Data(contentsOf: candidate.appendingPathComponent("Contents/Info.plist"))), "replacement installs the selected version")
            check(!fileManager.fileExists(atPath: success.stagingDirectory.path), "successful launch cleans backup and stage")
            let log = (try? String(contentsOf: launchLog, encoding: .utf8)) ?? ""
            check(log.contains(installed.path + "\n") && log.contains("--show-settings"), "special characters remain literal launcher arguments")
            if let pidText = try? String(contentsOf: root.appendingPathComponent("child-pid"), encoding: .utf8), let childPID = Int32(pidText) {
                _ = Darwin.kill(childPID, SIGTERM)
                Thread.sleep(forTimeInterval: 0.1)
            }

            let rollbackOldInfo = try Data(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))
            let rollbackCandidate = try fixture("Rollback candidate", version: "9.8.8")
            let rollbackZip = try archive(rollbackCandidate)
            let rollback = try UpdateInstaller.prepare(archiveURL: rollbackZip, version: "9.8.8", destinationURL: installed)
            try Data().write(to: root.appendingPathComponent("fail-first"))
            let rollbackTask = try runScript(rollback, pid: sleeper.processIdentifier)
            rollbackTask.waitUntilExit()
            check(rollbackTask.terminationStatus != 0, "launch failure reports unsuccessful installation")
            check((try? Data(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))) == rollbackOldInfo, "launch failure restores the complete old application")
            let rollbackLog = (try? String(contentsOf: launchLog, encoding: .utf8)) ?? ""
            check(rollbackLog.contains("--update-failed"), "rollback reopens old app with failure context")
            UpdateInstaller.discard(rollback)
            try fileManager.removeItem(at: root.appendingPathComponent("fail-first"))

            let interrupted = try UpdateInstaller.prepare(archiveURL: rollbackZip, version: "9.8.8", destinationURL: installed)
            let failMoveScript = UpdateInstaller.installScript.replacingOccurrences(of: "/bin/mv -h \"$new\" \"$destination\"", with: "/usr/bin/false")
            let interruptedTask = try process("/bin/sh", ["-c", failMoveScript, "OtterClip installer fixture", String(sleeper.processIdentifier), interrupted.stagingDirectory.path, installed.path, launcher.path])
            interruptedTask.waitUntilExit()
            check(interruptedTask.terminationStatus != 0, "replacement failure is reported")
            check((try? Data(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))) == rollbackOldInfo, "replacement failure restores old application")
            UpdateInstaller.discard(interrupted)

            let hung = try UpdateInstaller.prepare(archiveURL: rollbackZip, version: "9.8.8", destinationURL: installed)
            try Data().write(to: root.appendingPathComponent("no-ready"))
            let hungScript = UpdateInstaller.installScript.replacingOccurrences(of: "-lt 200", with: "-lt 3")
            let hungTask = try process("/bin/sh", ["-c", hungScript, "OtterClip installer fixture", String(sleeper.processIdentifier), hung.stagingDirectory.path, installed.path, launcher.path])
            hungTask.waitUntilExit()
            check(hungTask.terminationStatus != 0, "startup without healthy confirmation is rejected")
            check((try? Data(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))) == rollbackOldInfo, "unhealthy new process exits before rollback")
            UpdateInstaller.discard(hung)

            let noPID = try UpdateInstaller.prepare(archiveURL: rollbackZip, version: "9.8.8", destinationURL: installed)
            try Data().write(to: root.appendingPathComponent("no-pid"))
            let noPIDTask = try process("/bin/sh", ["-c", hungScript, "OtterClip installer fixture", String(sleeper.processIdentifier), noPID.stagingDirectory.path, installed.path, launcher.path])
            noPIDTask.waitUntilExit()
            check(noPIDTask.terminationStatus != 0, "startup failure before main is reported")
            check((try? Data(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))) == rollbackOldInfo, "no new process before main permits safe rollback")
            UpdateInstaller.discard(noPID)

            let unregistered = try UpdateInstaller.prepare(archiveURL: rollbackZip, version: "9.8.8", destinationURL: installed)
            try Data().write(to: root.appendingPathComponent("unregistered-process"))
            let unregisteredTask = try process("/bin/sh", ["-c", hungScript, "OtterClip installer fixture", String(sleeper.processIdentifier), unregistered.stagingDirectory.path, installed.path, launcher.path])
            unregisteredTask.waitUntilExit()
            check(unregisteredTask.terminationStatus != 0, "missing marker with a running new process is rejected")
            check((try? Data(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))) == rollbackOldInfo, "exact process path identifies and stops unregistered new app before rollback")
            UpdateInstaller.discard(unregistered)

            let handshake = try UpdateInstaller.prepare(archiveURL: rollbackZip, version: "9.8.8", destinationURL: installed)
            let token = String(handshake.stagingDirectory.lastPathComponent.dropFirst(".OtterClip-update-".count))
            try fileManager.copyItem(at: installed, to: handshake.stagingDirectory.appendingPathComponent("Previous.app"))
            UpdateInstaller.beginLaunchIfNeeded(arguments: ["fixture", "--update-token", "../../outside"], bundleURL: installed)
            check(!fileManager.fileExists(atPath: handshake.stagingDirectory.appendingPathComponent("launch-pid").path), "arbitrary marker paths are rejected")
            UpdateInstaller.beginLaunchIfNeeded(arguments: ["fixture", "--update-token", token], bundleURL: installed)
            UpdateInstaller.confirmLaunchIfNeeded(arguments: ["fixture", "--update-token", token], bundleURL: installed)
            check((try? String(contentsOf: handshake.stagingDirectory.appendingPathComponent("ready"), encoding: .utf8)) == String(ProcessInfo.processInfo.processIdentifier), "healthy startup writes marker only for its private adjacent stage")
            try fileManager.removeItem(at: handshake.stagingDirectory.appendingPathComponent("Previous.app"))
            UpdateInstaller.discard(handshake)
        } catch {
            failed += 1
            print("FAIL: installer fixture error: \(error.localizedDescription)")
        }
        print("Update installer checks: \(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
