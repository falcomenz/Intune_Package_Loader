import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showCleanupConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            storageCard
            packageSection
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 960, minHeight: 620)
        .alert("Clear mirrored packages?", isPresented: $showCleanupConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Cleanup", role: .destructive) {
                model.clearMirroredPackages()
            }
        } message: {
            Text("This removes mirrored package files from /Library/Application Support/Intune_Package_Loader/packages.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Intune Package Loader")
                    .font(.system(size: 28, weight: .semibold))

                HStack(spacing: 8) {
                    Circle()
                        .fill(model.isMirrorRunning ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)

                    Text(model.statusText)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 10) {
                Button("Refresh") {
                    model.refresh()
                }
                .disabled(model.isBusy)

                Button(model.isMirrorRunning ? "Stop Mirror" : "Start Mirror") {
                    if model.isMirrorRunning {
                        model.stopMirror()
                    } else {
                        model.startMirror()
                    }
                }
                .disabled(model.isBusy)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Storage")
                .font(.headline)

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("/Library/Application Support/Intune_Package_Loader")
                        .font(.system(.body, design: .monospaced))

                    Text("The GUI reads mirrored packages from this folder. The protected Intune staging path is copied there by the root helper.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 10) {
                    Button("Cleanup") {
                        showCleanupConfirmation = true
                    }
                    .disabled(model.isBusy)

                    Button("Open Folder") {
                        model.openPackagesFolder()
                    }
                    .disabled(model.isBusy)
                }
            }

            if let message = model.lastErrorMessage {
                Text(message)
                    .foregroundStyle(.red)
                    .font(.subheadline)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private var packageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Mirrored Packages")
                    .font(.headline)

                Spacer()

                Text("\(model.packages.count)")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }

            if model.packages.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)

                    Text(model.isMirrorRunning ? "Searching for packages..." : "No mirrored packages yet")
                        .font(.headline)

                    Text("Start the mirror, then install a macOS package app from Company Portal.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 260)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(NSColor.controlBackgroundColor))
                )
            } else {
                List(model.packages) { package in
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(package.name)
                                .font(.headline)

                            Text(package.relativePath)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 4) {
                            Text(package.formattedDate)
                                .font(.subheadline)
                            Text(package.formattedSize)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 8) {
                            Button("Copy Path") {
                                model.copyPath(package)
                            }

                            Button("Reveal") {
                                model.reveal(package)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .listStyle(.inset)
            }
        }
    }
}
