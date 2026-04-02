import AppKit
import Foundation

struct PackageItem: Identifiable, Hashable {
    let url: URL
    let relativePath: String
    let modifiedAt: Date
    let sizeBytes: Int64

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var formattedDate: String {
        modifiedAt.formatted(date: .abbreviated, time: .shortened)
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var packages: [PackageItem] = []
    @Published var statusText = "Mirror stopped"
    @Published var isMirrorRunning = false
    @Published var isBusy = false
    @Published var lastErrorMessage: String?

    let rootDirectory = URL(fileURLWithPath: defaultRootDirectoryPath, isDirectory: true)
    private var refreshTimer: Timer?
    private var autoStopTriggeredForPath: String?
    private var baselinePackagePaths: Set<String> = []

    var packagesDirectory: URL {
        rootDirectory.appendingPathComponent("packages", isDirectory: true)
    }

    init() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    func refresh() {
        packages = loadPackages()
        Task {
            let running = (try? await PrivilegedHelperClient.fetchStatus(rootDirectory: rootDirectory.path)) ?? false
            isMirrorRunning = running
            maybeAutoStopAfterPkg()
            statusText = buildStatusText()
        }
    }

    func startMirror() {
        isBusy = true
        lastErrorMessage = nil

        Task {
            do {
                try await PrivilegedHelperClient.startMirror(rootDirectory: rootDirectory.path)
                autoStopTriggeredForPath = nil
                baselinePackagePaths = Set(packages.map(\.id))
                isBusy = false
                refresh()
            } catch {
                isBusy = false
                lastErrorMessage = error.localizedDescription
                refresh()
            }
        }
    }

    func stopMirror() {
        isBusy = true
        lastErrorMessage = nil

        Task {
            do {
                try await PrivilegedHelperClient.stopMirror()
                baselinePackagePaths = []
                autoStopTriggeredForPath = nil
                isBusy = false
                refresh()
            } catch {
                isBusy = false
                lastErrorMessage = error.localizedDescription
                refresh()
            }
        }
    }

    func stopMirrorOnTerminationIfNeeded() {
        guard isMirrorRunning else { return }
        Task {
            try? await PrivilegedHelperClient.stopMirror()
        }
    }

    func openPackagesFolder() {
        NSWorkspace.shared.open(packagesDirectory)
    }

    func reveal(_ package: PackageItem) {
        NSWorkspace.shared.activateFileViewerSelecting([package.url])
    }

    func copyPath(_ package: PackageItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(package.url.path, forType: .string)
    }

    func clearMirroredPackages() {
        isBusy = true
        lastErrorMessage = nil

        Task {
            do {
                try await PrivilegedHelperClient.cleanupPackages(rootDirectory: rootDirectory.path)
                baselinePackagePaths = []
                autoStopTriggeredForPath = nil
                isBusy = false
                refresh()
            } catch {
                isBusy = false
                lastErrorMessage = error.localizedDescription
                refresh()
            }
        }
    }

    private func loadPackages() -> [PackageItem] {
        guard FileManager.default.fileExists(atPath: packagesDirectory.path) else {
            return []
        }

        let wantedExtensions = Set(["pkg", "dmg"])
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let enumerator = FileManager.default.enumerator(
            at: packagesDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        var collected: [PackageItem] = []

        while let url = enumerator?.nextObject() as? URL {
            guard wantedExtensions.contains(url.pathExtension.lowercased()) else { continue }

            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }

            let relativePath = url.path.replacingOccurrences(
                of: packagesDirectory.path + "/",
                with: ""
            )

            collected.append(
                PackageItem(
                    url: url,
                    relativePath: relativePath,
                    modifiedAt: values?.contentModificationDate ?? .distantPast,
                    sizeBytes: Int64(values?.fileSize ?? 0)
                )
            )
        }

        return collected.sorted { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.modifiedAt > rhs.modifiedAt
        }
    }

    private func buildStatusText() -> String {
        let newestPkg = packages.first(where: { $0.url.pathExtension.lowercased() == "pkg" })
        let newestNonPkg = packages.first

        if isMirrorRunning {
            if let newestPkg {
                return "Found pkg \(newestPkg.name)"
            }
            if let newestNonPkg {
                return "Waiting for .pkg (saw \(newestNonPkg.name))"
            }
            return "Searching for packages..."
        }

        if let newestPkg {
            return "Found pkg \(newestPkg.name)"
        }

        if let newestNonPkg {
            return "Mirror stopped. Latest file: \(newestNonPkg.name)"
        }

        return "Mirror stopped"
    }

    private func maybeAutoStopAfterPkg() {
        guard isMirrorRunning, !isBusy else { return }
        guard let newestPkg = packages.first(where: {
            $0.url.pathExtension.lowercased() == "pkg" && !baselinePackagePaths.contains($0.id)
        }) else { return }
        guard autoStopTriggeredForPath != newestPkg.url.path else { return }

        autoStopTriggeredForPath = newestPkg.url.path
        stopMirror()
    }
}
