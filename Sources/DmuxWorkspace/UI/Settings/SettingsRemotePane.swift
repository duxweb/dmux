import CoreImage.CIFilterBuiltins
import SwiftUI

struct RemoteSettingsPane: View {
    let model: AppModel
    @ObservedObject private var remoteHostService: RemoteHostService
    @State private var serverURL = ""

    init(model: AppModel) {
        self.model = model
        self.remoteHostService = model.remoteHostService
    }
    @State private var refreshToken = UUID()

    var body: some View {
        Form {
            Section(String(localized: "settings.remote.server", defaultValue: "Server", bundle: .module)) {
                TextField(String(localized: "settings.remote.server_url", defaultValue: "Relay Server URL", bundle: .module), text: Binding(
                    get: { serverURL.isEmpty ? model.appSettings.remote.serverURL : serverURL },
                    set: { serverURL = $0 }
                ))
                .onSubmit {
                    model.updateRemoteServerURL(serverURL)
                    refreshToken = UUID()
                }

                Toggle(String(localized: "settings.remote.enabled", defaultValue: "Enable Remote Host", bundle: .module), isOn: Binding(
                    get: { model.appSettings.remote.isEnabled },
                    set: {
                        if !serverURL.isEmpty {
                            model.updateRemoteServerURL(serverURL)
                        }
                        model.updateRemoteEnabled($0)
                        refreshToken = UUID()
                    }
                ))

                HStack {
                    Button(String(localized: "settings.remote.save", defaultValue: "Save Server", bundle: .module)) {
                        model.updateRemoteServerURL(serverURL.isEmpty ? model.appSettings.remote.serverURL : serverURL)
                        refreshToken = UUID()
                    }
                    Button(String(localized: "settings.remote.reconnect", defaultValue: "Reconnect", bundle: .module)) {
                        model.remoteHostService.start()
                        refreshToken = UUID()
                    }
                }

                Text(remoteHostService.snapshot.message)
                    .foregroundStyle(.secondary)
                    .id(refreshToken)
            }

            Section(String(localized: "settings.remote.pairing", defaultValue: "Pairing", bundle: .module)) {
                Button(String(localized: "settings.remote.create_pairing", defaultValue: "Create Pairing QR", bundle: .module)) {
                    model.remoteHostService.createPairing()
                    refreshToken = UUID()
                }
                if let pairing = remoteHostService.snapshot.pairing {
                    HStack(alignment: .top, spacing: 16) {
                        QRCodeView(text: pairing.qrPayload)
                            .frame(width: 160, height: 160)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Code: \(pairing.code)")
                                .font(.headline)
                            Text(pairing.qrPayload)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Text(String(localized: "settings.remote.qr_hint", defaultValue: "Mobile can scan this QR code or paste the payload.", bundle: .module))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section(String(localized: "settings.remote.pending", defaultValue: "Pending Pairing", bundle: .module)) {
                ForEach(remoteHostService.snapshot.pendingPairings) { pending in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(pending.deviceName)
                            Text(pending.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(String(localized: "settings.remote.confirm_pairing", defaultValue: "Confirm", bundle: .module)) {
                            model.remoteHostService.confirmPairing(pending.id)
                            refreshToken = UUID()
                        }
                    }
                }
            }

            Section(String(localized: "settings.remote.devices", defaultValue: "Devices", bundle: .module)) {
                Button(String(localized: "settings.remote.refresh_devices", defaultValue: "Refresh Devices", bundle: .module)) {
                    model.remoteHostService.refreshDevices()
                    refreshToken = UUID()
                }
                ForEach(remoteHostService.snapshot.devices) { device in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(device.name)
                            Text(device.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if device.revokedAt == nil {
                            Button(String(localized: "settings.remote.revoke", defaultValue: "Remove", bundle: .module), role: .destructive) {
                                model.remoteHostService.revokeDevice(device.id)
                                refreshToken = UUID()
                            }
                        } else {
                            Text(String(localized: "settings.remote.revoked", defaultValue: "Removed", bundle: .module))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .onAppear {
            serverURL = model.appSettings.remote.serverURL
            model.remoteHostService.refreshDevices()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct QRCodeView: View {
    let text: String
    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        if let image = makeImage() {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
        } else {
            RoundedRectangle(cornerRadius: 12).fill(.gray.opacity(0.15))
        }
    }

    private func makeImage() -> NSImage? {
        filter.message = Data(text.utf8)
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 160, height: 160))
    }
}
