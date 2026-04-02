import Foundation

private let stagingRootPrefix = "/private/var/folders/"
private let firstLevelRoot = URL(fileURLWithPath: "/private/var/folders", isDirectory: true)
private let intuneLogDirectory = URL(fileURLWithPath: "/Library/Logs/Microsoft/Intune", isDirectory: true)
private let scanInterval: TimeInterval = 0.02
private let installExtensions = Set(["pkg", "dmg"])

private struct InstallEvent {
    let timestamp: Date
    let policyID: String
    let appName: String
    let appType: String
    let weight: Int
}

private final class IntuneLogResolver {
    private let mirrorLogURL: URL
    private let fileManager = FileManager.default
    private let mirrorDateFormatter: DateFormatter
    private let intuneDateFormatter: DateFormatter
    private var mirrorLogFingerprint = ""
    private var intuneLogFingerprint = ""
    private var mirroredTimestampsByPath: [String: Date] = [:]
    private var installEvents: [InstallEvent] = []

    init(rootDirectory: URL) {
        mirrorLogURL = rootDirectory.appendingPathComponent("mirror.log", isDirectory: false)

        mirrorDateFormatter = DateFormatter()
        mirrorDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        mirrorDateFormatter.timeZone = .current
        mirrorDateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        intuneDateFormatter = DateFormatter()
        intuneDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        intuneDateFormatter.timeZone = .current
        intuneDateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss:SSS"
    }

    func resolveAppName(for mirroredURL: URL, fallbackTimestamp: Date) -> String? {
        reloadMirrorLogIfNeeded()
        reloadIntuneLogsIfNeeded()

        let mirroredAt = mirroredTimestampsByPath[mirroredURL.path] ?? fallbackTimestamp
        let expectedType = mirroredURL.pathExtension.uppercased()

        let candidates = installEvents
            .filter { $0.appType == expectedType }
            .filter { abs($0.timestamp.timeIntervalSince(mirroredAt)) <= 30 }

        let bestMatch = candidates.max { lhs, rhs in
            score(for: lhs, mirroredAt: mirroredAt) < score(for: rhs, mirroredAt: mirroredAt)
        }

        return bestMatch?.appName
    }

    private func score(for event: InstallEvent, mirroredAt: Date) -> Double {
        let distance = abs(event.timestamp.timeIntervalSince(mirroredAt))
        return Double(event.weight) - (distance * 100)
    }

    private func reloadMirrorLogIfNeeded() {
        let fingerprint = fileFingerprint(for: mirrorLogURL)
        guard fingerprint != mirrorLogFingerprint else { return }

        mirrorLogFingerprint = fingerprint
        mirroredTimestampsByPath = [:]

        guard let contents = try? String(contentsOf: mirrorLogURL, encoding: .utf8) else {
            return
        }

        for line in contents.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard let range = text.range(of: "  Saved as: ") else { continue }

            let timestampText = String(text[..<range.lowerBound])
            let path = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)

            guard
                let timestamp = mirrorDateFormatter.date(from: timestampText),
                !path.isEmpty
            else {
                continue
            }

            mirroredTimestampsByPath[path] = timestamp
        }
    }

    private func reloadIntuneLogsIfNeeded() {
        let logFiles = recentIntuneLogFiles(limit: 6)
        let fingerprint = logFiles.map(fileFingerprint(for:)).joined(separator: "|")
        guard fingerprint != intuneLogFingerprint else { return }

        intuneLogFingerprint = fingerprint
        installEvents = logFiles.flatMap(parseInstallEvents)
    }

    private func recentIntuneLogFiles(limit: Int) -> [URL] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: intuneLogDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return files
            .filter {
                $0.lastPathComponent.hasPrefix("IntuneMDMDaemon ") &&
                $0.pathExtension.lowercased() == "log"
            }
            .sorted {
                let lhsDate = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
            .prefix(limit)
            .map { $0 }
    }

    private func parseInstallEvents(from line: String) -> InstallEvent? {
        guard line.contains("AppName:") else { return nil }

        let lowered = line.lowercased()
        let weight: Int
        let inferredType: String?

        if line.contains("PkgInstaller | Starting PKG app installation") {
            weight = 1_000
            inferredType = "PKG"
        } else if line.contains("DmgInstaller | Starting DMG app installation") {
            weight = 1_000
            inferredType = "DMG"
        } else if lowered.contains("successfully downloaded app binary content") {
            weight = 950
            inferredType = nil
        } else if lowered.contains("starting app binary decryption for mac app policy") {
            weight = 925
            inferredType = nil
        } else if lowered.contains("starting app installation for mac app policy") {
            weight = 900
            inferredType = nil
        } else if lowered.contains("successfully installed all apps") {
            weight = 850
            inferredType = nil
        } else if lowered.contains("successful pkg installation") {
            weight = 840
            inferredType = "PKG"
        } else if lowered.contains("successful dmg installation") {
            weight = 840
            inferredType = "DMG"
        } else {
            return nil
        }

        guard
            let timestamp = parseTimestamp(from: line),
            let policyID = firstMatch(in: line, pattern: #"PolicyID: ([0-9A-Fa-f-]{36})"#),
            let appName = extractAppName(from: line)
        else {
            return nil
        }

        let appType = firstMatch(in: line, pattern: #"AppType: ([A-Z]+)"#) ?? inferredType ?? "PKG"
        return InstallEvent(timestamp: timestamp, policyID: policyID, appName: appName, appType: appType, weight: weight)
    }

    private func parseInstallEvents(from logFile: URL) -> [InstallEvent] {
        guard let contents = try? String(contentsOf: logFile, encoding: .utf8) else {
            return []
        }

        return contents
            .split(whereSeparator: \.isNewline)
            .compactMap { parseInstallEvents(from: String($0)) }
    }

    private func parseTimestamp(from line: String) -> Date? {
        guard line.count >= 23 else { return nil }
        return intuneDateFormatter.date(from: String(line.prefix(23)))
    }

    private func extractAppName(from line: String) -> String? {
        let marker = "AppName: "
        guard let startRange = line.range(of: marker) else { return nil }

        let start = startRange.upperBound
        let suffix = line[start...]
        let terminators = [
            ", BundleID:",
            ", AppType:",
            ", ComplianceState:",
            ", EnforcementState:",
            ", Primary BundleID:",
            ", Product Version",
        ]

        let end = terminators
            .compactMap { suffix.range(of: $0)?.lowerBound }
            .min() ?? line.endIndex

        let appName = String(line[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return appName.isEmpty ? nil : appName
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard
            let match = regex.firstMatch(in: text, options: [], range: range),
            match.numberOfRanges > 1,
            let resultRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }

        return String(text[resultRange])
    }

    private func fileFingerprint(for url: URL) -> String {
        guard
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
            let modifiedAt = values.contentModificationDate
        else {
            return ""
        }

        return "\(url.path)|\(modifiedAt.timeIntervalSince1970)|\(values.fileSize ?? 0)"
    }
}

private final class MirrorController {
    private let queue = DispatchQueue(label: "de.axelspringer.intune.package-loader.mirror-controller")
    private let fileManager = FileManager.default

    private var timer: DispatchSourceTimer?
    private var currentRootDirectory: URL?
    private var packagesDirectory: URL?
    private var pidFileURL: URL?
    private var logFileURL: URL?
    private var resolver: IntuneLogResolver?
    private var seenFingerprints = Set<String>()
    private var lastErrorMessage: String?

    func status(for rootDirectory: URL, reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            let isRunning = self.timer != nil && self.currentRootDirectory?.path == rootDirectory.path
            reply(isRunning, self.lastErrorMessage)
        }
    }

    func start(rootDirectory: URL, reply: @escaping (String?) -> Void) {
        queue.async {
            do {
                try self.startLocked(rootDirectory: rootDirectory)
                reply(nil)
            } catch {
                self.lastErrorMessage = error.localizedDescription
                reply(error.localizedDescription)
            }
        }
    }

    func stop(reply: @escaping (String?) -> Void) {
        queue.async {
            self.stopLocked()
            reply(nil)
        }
    }

    func cleanup(rootDirectory: URL, reply: @escaping (String?) -> Void) {
        queue.async {
            do {
                let packagesDirectory = rootDirectory.appendingPathComponent("packages", isDirectory: true)
                try self.fileManager.createDirectory(at: packagesDirectory, withIntermediateDirectories: true)

                if let contents = try? self.fileManager.contentsOfDirectory(at: packagesDirectory, includingPropertiesForKeys: nil) {
                    for entry in contents {
                        try? self.fileManager.removeItem(at: entry)
                    }
                }

                self.seenFingerprints.removeAll()
                self.lastErrorMessage = nil
                self.appendLog(rootDirectory: rootDirectory, message: "Mirrored packages removed")
                reply(nil)
            } catch {
                self.lastErrorMessage = error.localizedDescription
                reply(error.localizedDescription)
            }
        }
    }

    private func startLocked(rootDirectory: URL) throws {
        if currentRootDirectory?.path != rootDirectory.path {
            stopLocked()
        }

        if timer != nil {
            return
        }

        currentRootDirectory = rootDirectory
        packagesDirectory = rootDirectory.appendingPathComponent("packages", isDirectory: true)
        pidFileURL = rootDirectory.appendingPathComponent("mirror.pid", isDirectory: false)
        logFileURL = rootDirectory.appendingPathComponent("mirror.log", isDirectory: false)
        resolver = IntuneLogResolver(rootDirectory: rootDirectory)
        seenFingerprints.removeAll()
        lastErrorMessage = nil

        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: packagesDirectory!, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: logFileURL!.path) {
            fileManager.createFile(atPath: logFileURL!.path, contents: Data())
        }
        try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: logFileURL!.path)
        writePID()

        appendLog(rootDirectory: rootDirectory, message: "Watching Intune staging paths under \(firstLevelRoot.path)")
        appendLog(rootDirectory: rootDirectory, message: "Output directory: \(packagesDirectory!.path)")
        appendLog(rootDirectory: rootDirectory, message: "Polling interval: \(String(format: "%.02f", scanInterval))s")

        normalizeExistingPackages()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: scanInterval)
        timer.setEventHandler { [weak self] in
            self?.scanOnce()
        }
        self.timer = timer
        timer.resume()
    }

    private func stopLocked() {
        if timer != nil, let rootDirectory = currentRootDirectory {
            appendLog(rootDirectory: rootDirectory, message: "Mirror service stopping")
        }

        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        resolver = nil
        currentRootDirectory = nil
        packagesDirectory = nil
        seenFingerprints.removeAll()
        cleanupPID()
    }

    private func scanOnce() {
        guard let packagesDirectory else { return }

        for root in stagingRoots() {
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            while let fileURL = enumerator?.nextObject() as? URL {
                do {
                    let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                    guard values.isRegularFile == true else { continue }

                    guard let fingerprint = fingerprint(for: fileURL) else { continue }
                    guard !seenFingerprints.contains(fingerprint) else { continue }

                    try copyCandidate(fileURL, into: packagesDirectory)
                    seenFingerprints.insert(fingerprint)
                } catch {
                    lastErrorMessage = error.localizedDescription
                    if let rootDirectory = currentRootDirectory {
                        appendLog(rootDirectory: rootDirectory, message: "Skipping \(fileURL.path): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func stagingRoots() -> [URL] {
        guard let firstLevelDirectories = try? fileManager.contentsOfDirectory(
            at: firstLevelRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var roots: [URL] = []

        for firstLevel in firstLevelDirectories where isDirectory(firstLevel) {
            guard let secondLevelDirectories = try? fileManager.contentsOfDirectory(
                at: firstLevel,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for secondLevel in secondLevelDirectories where isDirectory(secondLevel) {
                let candidate = secondLevel
                    .appendingPathComponent("T", isDirectory: true)
                    .appendingPathComponent("com.microsoft.intuneMDMAgent", isDirectory: true)

                if fileManager.fileExists(atPath: candidate.path) {
                    roots.append(candidate)
                }
            }
        }

        return roots
    }

    private func copyCandidate(_ sourceURL: URL, into outputDirectory: URL) throws {
        guard let rootDirectory = currentRootDirectory else { return }

        let sourcePath = sourceURL.path
        guard sourcePath.hasPrefix(stagingRootPrefix) else { return }

        let relativePath = String(sourcePath.dropFirst(stagingRootPrefix.count))
        let destinationURL = outputDirectory.appendingPathComponent(relativePath, isDirectory: false)
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        let temporaryURL = destinationDirectory.appendingPathComponent(".\(destinationURL.lastPathComponent).partial")

        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: temporaryURL.path) {
            try? fileManager.removeItem(at: temporaryURL)
        }

        try fileManager.copyItem(at: sourceURL, to: temporaryURL)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: temporaryURL, to: destinationURL)

        appendLog(rootDirectory: rootDirectory, message: "Mirrored: \(sourcePath)")
        appendLog(rootDirectory: rootDirectory, message: "Saved as: \(destinationURL.path)")

        if let finalURL = try renameMirroredInstallIfNeeded(at: destinationURL), finalURL.path != destinationURL.path {
            appendLog(rootDirectory: rootDirectory, message: "Renamed package to: \(finalURL.path)")
        }
    }

    private func normalizeExistingPackages() {
        guard let packagesDirectory else { return }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: packagesDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        while let fileURL = enumerator.nextObject() as? URL {
            guard installExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }

            do {
                _ = try renameMirroredInstallIfNeeded(at: fileURL)
            } catch {
                if let rootDirectory = currentRootDirectory {
                    appendLog(rootDirectory: rootDirectory, message: "Could not normalize \(fileURL.path): \(error.localizedDescription)")
                }
            }
        }
    }

    private func renameMirroredInstallIfNeeded(at url: URL) throws -> URL? {
        let ext = url.pathExtension.lowercased()
        guard installExtensions.contains(ext) else { return nil }

        let currentBaseName = url.deletingPathExtension().lastPathComponent
        guard looksLikeGeneratedFileName(currentBaseName) else { return url }

        let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        guard let appName = resolver?.resolveAppName(for: url, fallbackTimestamp: modifiedAt) else {
            return url
        }

        let preferredFileName = sanitizedFileName(for: appName, originalExtension: ext)
        let destinationURL = uniqueDestination(for: preferredFileName, nextTo: url)
        guard destinationURL.path != url.path else { return url }

        try fileManager.moveItem(at: url, to: destinationURL)
        return destinationURL
    }

    private func sanitizedFileName(for appName: String, originalExtension: String) -> String {
        var sanitized = appName.trimmingCharacters(in: .whitespacesAndNewlines)

        if sanitized.lowercased().hasSuffix(".\(originalExtension)") {
            sanitized = String(sanitized.dropLast(originalExtension.count + 1))
        }

        sanitized = sanitized
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))

        if sanitized.isEmpty {
            sanitized = "Intune Package"
        }

        return "\(sanitized).\(originalExtension)"
    }

    private func uniqueDestination(for preferredFileName: String, nextTo originalURL: URL) -> URL {
        let directory = originalURL.deletingLastPathComponent()
        let preferredURL = directory.appendingPathComponent(preferredFileName, isDirectory: false)

        if preferredURL.path == originalURL.path || !fileManager.fileExists(atPath: preferredURL.path) {
            return preferredURL
        }

        let baseName = preferredURL.deletingPathExtension().lastPathComponent
        let ext = preferredURL.pathExtension
        var index = 2

        while true {
            let candidate = directory.appendingPathComponent("\(baseName) (\(index)).\(ext)", isDirectory: false)
            if candidate.path == originalURL.path || !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    private func looksLikeGeneratedFileName(_ name: String) -> Bool {
        firstMatch(in: name, pattern: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#) != nil
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }

        guard let matchRange = Range(match.range(at: 0), in: text) else {
            return nil
        }

        return String(text[matchRange])
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func fingerprint(for url: URL) -> String? {
        var statBuffer = stat()
        guard lstat(url.path, &statBuffer) == 0 else { return nil }
        return "\(url.path)|\(statBuffer.st_ino)|\(statBuffer.st_size)|\(statBuffer.st_mtimespec.tv_sec)"
    }

    private func writePID() {
        guard let pidFileURL else { return }
        let pidString = "\(getpid())\n"
        try? pidString.write(to: pidFileURL, atomically: true, encoding: .utf8)
        try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pidFileURL.path)
    }

    private func cleanupPID() {
        guard let pidFileURL else { return }
        try? fileManager.removeItem(at: pidFileURL)
    }

    private func appendLog(rootDirectory: URL, message: String) {
        let logFileURL = rootDirectory.appendingPathComponent("mirror.log", isDirectory: false)
        if !fileManager.fileExists(atPath: logFileURL.path) {
            fileManager.createFile(atPath: logFileURL.path, contents: Data())
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(formatter.string(from: Date()))  \(message)\n"

        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}

private final class PrivilegedMirrorService: NSObject, NSXPCListenerDelegate, IntunePackageMirrorHelperProtocol {
    private let controller = MirrorController()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: IntunePackageMirrorHelperProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func fetchMirrorStatus(_ rootDirectory: String, withReply reply: @escaping (Bool, String?) -> Void) {
        controller.status(for: URL(fileURLWithPath: rootDirectory, isDirectory: true), reply: reply)
    }

    func startMirror(_ rootDirectory: String, withReply reply: @escaping (String?) -> Void) {
        controller.start(rootDirectory: URL(fileURLWithPath: rootDirectory, isDirectory: true), reply: reply)
    }

    func stopMirror(withReply reply: @escaping (String?) -> Void) {
        controller.stop(reply: reply)
    }

    func cleanupPackages(_ rootDirectory: String, withReply reply: @escaping (String?) -> Void) {
        controller.cleanup(rootDirectory: URL(fileURLWithPath: rootDirectory, isDirectory: true), reply: reply)
    }
}

private let listener = NSXPCListener(machServiceName: privilegedHelperLabel)
private let service = PrivilegedMirrorService()
listener.delegate = service
listener.resume()
RunLoop.main.run()
