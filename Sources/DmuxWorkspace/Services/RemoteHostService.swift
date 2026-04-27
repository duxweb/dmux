import AppKit
import Combine
import Foundation

extension Notification.Name {
  static let coduxTerminalOutputDidReceive = Notification.Name("codux.terminalOutputDidReceive")
}

enum RemoteHostStatus: String, Codable, Equatable {
  case stopped
  case registering
  case connecting
  case connected
  case failed
}

struct RemoteHostDevice: Codable, Equatable, Identifiable {
  var id: String
  var hostId: String
  var name: String
  var publicKey: String
  var createdAt: Date
  var lastSeen: Date
  var revokedAt: Date?
}

struct RemotePairingInfo: Codable, Equatable {
  var pairingId: String
  var code: String
  var secret: String
  var expiresAt: Date
  var qrPayload: String
}

@MainActor
final class RemoteHostService: ObservableObject {
  struct PendingPairing: Equatable, Identifiable {
    var id: String
    var deviceName: String
    var devicePublicKey: String
  }

  struct Snapshot: Equatable {
    var status: RemoteHostStatus = .stopped
    var message: String = "Remote Host stopped."
    var pairing: RemotePairingInfo?
    var devices: [RemoteHostDevice] = []
    var pendingPairings: [PendingPairing] = []
  }

  private weak var model: AppModel?
  private var socket: URLSessionWebSocketTask?
  private var activeSocketURL: URL?
  private var isStarting = false
  private var outputObserver: NSObjectProtocol?
  private var pingTimer: Timer?
  private var terminalOutputBuffer: [String: String] = [:]
  private var remoteProcessBridges: [UUID: GhosttyPTYProcessBridge] = [:]
  private let maxTerminalBufferCharacters = 120_000
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  @Published private(set) var snapshot = Snapshot()

  init(model: AppModel) {
    self.model = model
    encoder.dateEncodingStrategy = .iso8601
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = formatter.date(from: value) {
        return date
      }
      formatter.formatOptions = [.withInternetDateTime]
      if let date = formatter.date(from: value) {
        return date
      }
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Invalid ISO8601 date: \(value)")
    }
  }

  func applySettings() {
    guard let model else { return }
    if model.appSettings.remote.isEnabled {
      start()
    } else {
      stop()
    }
  }

  func start() {
    guard let model else { return }
    guard model.appSettings.remote.isEnabled else {
      stop()
      return
    }
    guard
      !model.appSettings.remote.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      update(status: .failed, message: "Remote server URL is empty.")
      return
    }
    guard isStarting == false else { return }
    if socket != nil, snapshot.status == .connected {
      return
    }
    Task { await registerHostAndConnect() }
  }

  func stop() {
    stopPingTimer()
    socket?.cancel(with: .normalClosure, reason: nil)
    socket = nil
    activeSocketURL = nil
    isStarting = false
    update(status: .stopped, message: "Remote Host stopped.")
  }

  func createPairing() {
    Task { await requestPairing() }
  }

  func refreshDevices() {
    Task { await loadDevices() }
  }

  func confirmPairing(_ pairingID: String) {
    Task { await confirm(pairingID: pairingID) }
  }

  func revokeDevice(_ deviceID: String) {
    Task { await revoke(deviceID: deviceID) }
  }

  private func registerHostAndConnect() async {
    guard let model else { return }
    guard isStarting == false else { return }
    isStarting = true
    update(status: .registering, message: "Registering Remote Host…")
    var settings = model.appSettings.remote
    if settings.hostID.isEmpty { settings.hostID = UUID().uuidString }
    if settings.hostToken.isEmpty { settings.hostToken = randomToken() }
    let body: [String: String] = [
      "hostId": settings.hostID, "name": Host.current().localizedName ?? "Codux Mac",
      "token": settings.hostToken, "publicKey": "",
    ]
    do {
      struct RegisterResponse: Decodable {
        var hostId: String
        var token: String
      }
      let response: RegisterResponse = try await post(path: "/api/hosts/register", body: body)
      settings.hostID = response.hostId
      settings.hostToken = response.token
      model.updateRemoteSettings(settings, reconnect: false)
      connectSocket()
      await loadDevices()
    } catch {
      update(status: .failed, message: remoteErrorMessage(error))
    }
    isStarting = false
  }

  private func connectSocket() {
    guard let model,
      let url = remoteURL(
        path: "/ws/host",
        queryItems: [
          URLQueryItem(name: "hostId", value: model.appSettings.remote.hostID),
          URLQueryItem(name: "token", value: model.appSettings.remote.hostToken),
        ], websocket: true)
    else { return }
    if socket != nil, activeSocketURL == url, snapshot.status == .connected {
      return
    }
    update(status: .connecting, message: "Connecting relay…")
    socket?.cancel(with: .goingAway, reason: nil)
    activeSocketURL = url
    let task = URLSession.shared.webSocketTask(with: url)
    socket = task
    task.resume()
    update(status: .connected, message: "Remote Host connected.")
    startPingTimer()
    observeTerminalOutputIfNeeded()
    receiveLoop()
  }

  private func receiveLoop() {
    socket?.receive { [weak self] result in
      Task { @MainActor in
        guard let self else { return }
        switch result {
        case .success(let message):
          self.handle(message)
          self.receiveLoop()
        case .failure(let error):
          if self.socket != nil {
            self.stopPingTimer()
            self.socket = nil
            self.activeSocketURL = nil
            self.update(status: .failed, message: error.localizedDescription)
          }
        }
      }
    }
  }

  private func startPingTimer() {
    stopPingTimer()
    pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, let socket = self.socket else { return }
        socket.sendPing { [weak self] error in
          guard let error else { return }
          Task { @MainActor in
            guard let self, self.socket === socket else { return }
            self.stopPingTimer()
            self.socket = nil
            self.activeSocketURL = nil
            self.update(
              status: .failed, message: "Remote ping failed: \(error.localizedDescription)")
            socket.cancel(with: .goingAway, reason: nil)
          }
        }
      }
    }
    if let pingTimer { RunLoop.main.add(pingTimer, forMode: .common) }
  }

  private func stopPingTimer() {
    pingTimer?.invalidate()
    pingTimer = nil
  }

  private func handle(_ message: URLSessionWebSocketTask.Message) {
    let data: Data?
    switch message {
    case .data(let value): data = value
    case .string(let value): data = value.data(using: .utf8)
    @unknown default: data = nil
    }
    guard let data, let envelope = try? decoder.decode(RemoteEnvelope.self, from: data) else {
      return
    }
    switch envelope.type {
    case "pairing.request":
      let pairingID = envelope.payload?["pairingId"] as? String ?? ""
      let deviceName = envelope.payload?["deviceName"] as? String ?? "Mobile Device"
      let devicePublicKey = envelope.payload?["devicePublicKey"] as? String ?? ""
      if !pairingID.isEmpty,
        snapshot.pendingPairings.contains(where: { $0.id == pairingID }) == false
      {
        snapshot.pendingPairings.append(
          PendingPairing(id: pairingID, deviceName: deviceName, devicePublicKey: devicePublicKey))
        snapshot.message = "Pairing request from \(deviceName)."
      }
    case "host.info":
      send(
        type: "host.info", deviceID: envelope.deviceID,
        payload: ["name": Host.current().localizedName ?? "Codux Mac"])
    case "device.info":
      refreshDevices()
    case "project.list":
      send(
        type: "project.list", deviceID: envelope.deviceID,
        payload: ["projects": model?.remoteProjects() ?? []])
    case "terminal.list":
      send(
        type: "terminal.list", deviceID: envelope.deviceID,
        payload: ["terminals": model?.remoteTerminals() ?? []])
    case "file.list":
      let requestedPath = envelope.payload?["path"] as? String
      let purpose = envelope.payload?["purpose"] as? String
      send(
        type: "file.list", deviceID: envelope.deviceID,
        payload: remoteFileList(path: requestedPath, purpose: purpose)
      )
    case "file.read":
      if let path = envelope.payload?["path"] as? String {
        do {
          send(
            type: "file.read", deviceID: envelope.deviceID, payload: try remoteFileRead(path: path))
        } catch {
          send(
            type: "error", deviceID: envelope.deviceID,
            payload: ["message": error.localizedDescription])
        }
      }
    case "file.write":
      if let path = envelope.payload?["path"] as? String,
        let content = envelope.payload?["content"] as? String
      {
        do {
          try remoteFileWrite(path: path, content: content)
          send(type: "file.written", deviceID: envelope.deviceID, payload: ["path": path])
        } catch {
          send(
            type: "error", deviceID: envelope.deviceID,
            payload: ["message": error.localizedDescription])
        }
      }
    case "project.add":
      if let path = envelope.payload?["path"] as? String,
        let project = model?.remoteAddProject(
          path: path, name: envelope.payload?["name"] as? String)
      {
        send(
          type: "project.updated", deviceID: envelope.deviceID,
          payload: ["action": "add", "projectId": project.id.uuidString])
        send(
          type: "project.list", deviceID: envelope.deviceID,
          payload: ["projects": model?.remoteProjects() ?? []])
        send(
          type: "terminal.list", deviceID: envelope.deviceID,
          payload: ["terminals": model?.remoteTerminals() ?? []])
      } else {
        send(
          type: "error", deviceID: envelope.deviceID, payload: ["message": "Unable to add project"])
      }
    case "project.edit":
      if let projectID = envelope.payload?["projectId"] as? String,
        let path = envelope.payload?["path"] as? String,
        let project = model?.remoteEditProject(
          projectID: projectID, path: path, name: envelope.payload?["name"] as? String)
      {
        send(
          type: "project.updated", deviceID: envelope.deviceID,
          payload: ["action": "edit", "projectId": project.id.uuidString])
        send(
          type: "project.list", deviceID: envelope.deviceID,
          payload: ["projects": model?.remoteProjects() ?? []])
        send(
          type: "terminal.list", deviceID: envelope.deviceID,
          payload: ["terminals": model?.remoteTerminals() ?? []])
      } else {
        send(
          type: "error", deviceID: envelope.deviceID, payload: ["message": "Unable to edit project"]
        )
      }
    case "project.remove":
      if let projectID = envelope.payload?["projectId"] as? String,
        model?.remoteRemoveProject(projectID: projectID) == true
      {
        send(
          type: "project.updated", deviceID: envelope.deviceID,
          payload: ["action": "remove", "projectId": projectID])
        send(
          type: "project.list", deviceID: envelope.deviceID,
          payload: ["projects": model?.remoteProjects() ?? []])
        send(
          type: "terminal.list", deviceID: envelope.deviceID,
          payload: ["terminals": model?.remoteTerminals() ?? []])
      } else {
        send(
          type: "error", deviceID: envelope.deviceID,
          payload: ["message": "Unable to remove project"])
      }
    case "ai.stats":
      if let projectID = envelope.payload?["projectId"] as? String,
        let stats = model?.remoteAIStats(projectID: projectID)
      {
        send(type: "ai.stats", deviceID: envelope.deviceID, payload: stats)
      } else {
        send(
          type: "error", deviceID: envelope.deviceID,
          payload: ["message": "Unable to load AI stats"])
      }
    case "terminal.buffer":
      if let sessionID = envelope.sessionID {
        sendTerminalBuffer(sessionID: sessionID, deviceID: envelope.deviceID)
      }
    case "terminal.create":
      let projectID = envelope.payload?["projectId"] as? String
      let command = envelope.payload?["command"] as? String ?? ""
      if let session = model?.remoteCreateTerminal(projectID: projectID, command: command) {
        let sessionID = session.id.uuidString
        send(
          type: "terminal.created", deviceID: envelope.deviceID, sessionID: sessionID,
          payload: [
            "id": sessionID, "title": session.title, "projectId": session.projectID.uuidString,
          ])
        startRemoteProcessIfNeeded(for: session, deviceID: envelope.deviceID)
        sendTerminalBuffer(sessionID: sessionID, deviceID: envelope.deviceID)
      } else {
        send(
          type: "error", deviceID: envelope.deviceID,
          payload: ["message": "Unable to create terminal"])
      }
    case "terminal.input":
      if let sessionID = envelope.sessionID.flatMap(UUID.init(uuidString:)),
        let data = envelope.payload?["data"] as? String
      {
        if let bridge = remoteProcessBridges[sessionID] {
          bridge.sendText(data)
        } else {
          let sent = DmuxTerminalBackend.shared.registry.sendText(data, to: sessionID)
          if sent == false {
            send(
              type: "error", deviceID: envelope.deviceID, sessionID: sessionID.uuidString,
              payload: [
                "message":
                  "Terminal is not ready yet. Please create it again or select a running terminal."
              ])
          }
        }
      }
    case "terminal.resize":
      if let sessionID = envelope.sessionID.flatMap(UUID.init(uuidString:)),
        let colsValue = envelope.payload?["cols"],
        let rowsValue = envelope.payload?["rows"]
      {
        let cols = UInt16(clamping: UInt((colsValue as? Int) ?? Int((colsValue as? Double) ?? 0)))
        let rows = UInt16(clamping: UInt((rowsValue as? Int) ?? Int((rowsValue as? Double) ?? 0)))
        if cols > 0, rows > 0 {
          if let bridge = remoteProcessBridges[sessionID] {
            bridge.resize(columns: cols, rows: rows)
          } else {
            _ = DmuxTerminalBackend.shared.registry.resize(
              columns: cols, rows: rows, sessionID: sessionID)
          }
        }
      }
    case "terminal.upload":
      handleTerminalUpload(envelope)
    case "terminal.close":
      if let sessionID = envelope.sessionID.flatMap(UUID.init(uuidString:)) {
        if let bridge = remoteProcessBridges.removeValue(forKey: sessionID) {
          bridge.terminateProcessTree()
        }
        if model?.remoteCloseTerminal(sessionID: sessionID) == true {
          terminalOutputBuffer.removeValue(forKey: sessionID.uuidString)
          send(
            type: "terminal.closed", deviceID: envelope.deviceID, sessionID: sessionID.uuidString,
            payload: ["id": sessionID.uuidString])
          send(
            type: "terminal.list", deviceID: envelope.deviceID,
            payload: ["terminals": model?.remoteTerminals() ?? []])
        }
      }
    case "terminal.signal":
      if let sessionID = envelope.sessionID.flatMap(UUID.init(uuidString:)) {
        let signal = envelope.payload?["signal"] as? String
        if signal == "interrupt" {
          _ = DmuxTerminalBackend.shared.registry.sendInterrupt(to: sessionID)
        }
        if signal == "escape" { _ = DmuxTerminalBackend.shared.registry.sendEscape(to: sessionID) }
      }
    default:
      break
    }
  }

  private func remoteFileList(path: String?, purpose: String?) -> [String: Any] {
    let fileManager = FileManager.default
    let home = fileManager.homeDirectoryForCurrentUser.path
    let resolvedPath =
      (path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? path! : home)
    let url = URL(fileURLWithPath: resolvedPath, isDirectory: true).standardizedFileURL
    let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    let directoryURL = isDirectory ? url : url.deletingLastPathComponent()
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey, .nameKey]
    let entries =
      (try? fileManager.contentsOfDirectory(
        at: directoryURL, includingPropertiesForKeys: Array(keys),
        options: [.skipsPackageDescendants])) ?? []
    let mapped = entries.compactMap { entry -> [String: Any]? in
      guard let values = try? entry.resourceValues(forKeys: keys) else { return nil }
      if values.isHidden == true { return nil }
      let name = values.name ?? entry.lastPathComponent
      return [
        "name": name,
        "path": entry.path,
        "isDirectory": values.isDirectory == true,
      ]
    }
    .sorted { lhs, rhs in
      let lhsDirectory = lhs["isDirectory"] as? Bool == true
      let rhsDirectory = rhs["isDirectory"] as? Bool == true
      if lhsDirectory != rhsDirectory { return lhsDirectory && !rhsDirectory }
      return ((lhs["name"] as? String) ?? "").localizedStandardCompare(
        (rhs["name"] as? String) ?? "") == .orderedAscending
    }
    var payload: [String: Any] = [
      "path": directoryURL.path,
      "parent": directoryURL.deletingLastPathComponent().path,
      "entries": mapped,
    ]
    if let purpose { payload["purpose"] = purpose }
    return payload
  }

  private func remoteFileRead(path: String) throws -> [String: Any] {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
    if values.isDirectory == true {
      throw NSError(
        domain: "CoduxRemote", code: 400,
        userInfo: [NSLocalizedDescriptionKey: "Cannot open a directory as a file"])
    }
    let maxBytes = 2 * 1024 * 1024
    if let fileSize = values.fileSize, fileSize > maxBytes {
      throw NSError(
        domain: "CoduxRemote", code: 413,
        userInfo: [
          NSLocalizedDescriptionKey: "File is larger than 2MB and cannot be opened on mobile yet"
        ])
    }
    let data = try Data(contentsOf: url)
    guard let content = String(data: data, encoding: .utf8) else {
      throw NSError(
        domain: "CoduxRemote", code: 415,
        userInfo: [NSLocalizedDescriptionKey: "Only UTF-8 text files can be edited on mobile"])
    }
    return ["path": url.path, "name": url.lastPathComponent, "content": content, "size": data.count]
  }

  private func remoteFileWrite(path: String, content: String) throws {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    try content.data(using: .utf8)?.write(to: url, options: .atomic)
  }

  private func handleTerminalUpload(_ envelope: RemoteEnvelope) {
    guard let sessionID = envelope.sessionID,
      let payload = envelope.payload,
      let base64Value = payload["data"] as? String,
      let fileData = Data(base64Encoded: base64Value)
    else {
      send(
        type: "error", deviceID: envelope.deviceID, sessionID: envelope.sessionID,
        payload: ["message": "Invalid upload payload"])
      return
    }
    let rawName = (payload["name"] as? String) ?? "upload.png"
    let safeName = sanitizedUploadFileName(rawName)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("CoduxUploads", isDirectory: true)
      .appendingPathComponent(sessionID, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = uniqueUploadURL(directory: directory, fileName: safeName)
      try fileData.write(to: url, options: .atomic)
      let insertion = insertUploadedImage(
        url: url, data: fileData, mime: payload["mime"] as? String, sessionID: sessionID)
      send(
        type: "terminal.uploaded", deviceID: envelope.deviceID, sessionID: sessionID,
        payload: [
          "path": url.path, "name": url.lastPathComponent, "mode": insertion.mode,
          "tool": insertion.tool as Any, "inserted": true,
        ])
    } catch {
      send(
        type: "error", deviceID: envelope.deviceID, sessionID: sessionID,
        payload: ["message": "Upload failed: \(error.localizedDescription)"])
    }
  }

  private func insertUploadedImage(url: URL, data: Data, mime: String?, sessionID: String) -> (
    mode: String, tool: String?
  ) {
    let uuid = UUID(uuidString: sessionID)
    let tool = uuid.flatMap { activeAITool(for: $0) }
    if let uuid, let bridge = remoteProcessBridges[uuid], let tool,
      supportsClipboardImagePaste(tool)
    {
      prepareImagePasteboard(url: url, data: data, mime: mime)
      bridge.sendText("\u{16}")
      return ("clipboard", tool)
    }
    let text = "\(url.path) "
    if let uuid, let bridge = remoteProcessBridges[uuid] {
      bridge.sendText(text)
    } else if let uuid {
      _ = DmuxTerminalBackend.shared.registry.sendText(text, to: uuid)
    }
    return ("path", tool)
  }

  private func activeAITool(for sessionID: UUID) -> String? {
    if let shellPID = remoteProcessBridges[sessionID]?.currentShellPID,
      let tool = TerminalProcessInspector().activeTool(forShellPID: shellPID)
    {
      return tool
    }
    guard let command = model?.terminalSession(for: sessionID)?.command.lowercased() else {
      return nil
    }
    if command.contains("claude") { return "claude" }
    if command.contains("codex") { return "codex" }
    if command.contains("gemini") { return "gemini" }
    if command.contains("opencode") { return "opencode" }
    return nil
  }

  private func supportsClipboardImagePaste(_ tool: String) -> Bool {
    ["claude", "codex", "gemini", "opencode"].contains(tool.lowercased())
  }

  private func prepareImagePasteboard(url: URL, data: Data, mime: String?) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(url.absoluteString, forType: .fileURL)
    let normalizedMime = mime?.lowercased() ?? ""
    if normalizedMime.contains("png") {
      pasteboard.setData(data, forType: .png)
    } else if normalizedMime.contains("jpeg") || normalizedMime.contains("jpg") {
      pasteboard.setData(data, forType: NSPasteboard.PasteboardType("public.jpeg"))
    }
    if let image = NSImage(data: data) {
      pasteboard.writeObjects([image])
      if let tiff = image.tiffRepresentation {
        pasteboard.setData(tiff, forType: .tiff)
      }
    }
  }

  private func sanitizedUploadFileName(_ value: String) -> String {
    let fallback = "upload.png"
    let last = URL(fileURLWithPath: value).lastPathComponent
    let cleaned = last.map { char -> Character in
      if char.isLetter || char.isNumber || char == "." || char == "-" || char == "_" { return char }
      return "_"
    }
    let result = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    return result.isEmpty ? fallback : result
  }

  private func uniqueUploadURL(directory: URL, fileName: String) -> URL {
    let base = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
    let ext = URL(fileURLWithPath: fileName).pathExtension
    var candidate = directory.appendingPathComponent(fileName)
    var index = 1
    while FileManager.default.fileExists(atPath: candidate.path) {
      let nextName = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
      candidate = directory.appendingPathComponent(nextName)
      index += 1
    }
    return candidate
  }

  private func observeTerminalOutputIfNeeded() {
    guard outputObserver == nil else { return }
    outputObserver = NotificationCenter.default.addObserver(
      forName: .coduxTerminalOutputDidReceive, object: nil, queue: .main
    ) { [weak self] notification in
      guard let self,
        let sessionID = notification.userInfo?["sessionID"] as? UUID,
        let data = notification.userInfo?["data"] as? Data,
        let text = String(data: data, encoding: .utf8)
      else { return }
      Task { @MainActor in
        let key = sessionID.uuidString
        self.appendBuffer(sessionID: key, text: text)
        self.send(type: "terminal.output", sessionID: key, payload: ["data": text])
      }
    }
  }

  private func startRemoteProcessIfNeeded(for session: TerminalSession, deviceID: String?) {
    guard remoteProcessBridges[session.id] == nil else { return }
    let bridge = GhosttyPTYProcessBridge(sessionID: session.id, suppressPromptEolMark: true)
    remoteProcessBridges[session.id] = bridge
    let sessionID = session.id.uuidString
    bridge.onOutput = { [weak self] data in
      Task { @MainActor in
        guard let self, let text = String(data: data, encoding: .utf8) else { return }
        self.appendBuffer(sessionID: sessionID, text: text)
        self.send(
          type: "terminal.output", deviceID: deviceID, sessionID: sessionID, payload: ["data": text]
        )
      }
    }
    bridge.onProcessTerminated = { [weak self] exitCode in
      Task { @MainActor in
        guard let self else { return }
        self.remoteProcessBridges[session.id] = nil
        _ = exitCode
      }
    }
    let environment = ProcessInfo.processInfo.environment.map { ($0.key, $0.value) }
    bridge.start(
      shell: session.shell,
      shellName: URL(fileURLWithPath: session.shell).lastPathComponent,
      command: session.command,
      cwd: session.cwd,
      environment: environment
    )
  }

  private func appendBuffer(sessionID: String, text: String) {
    guard text.isEmpty == false else { return }
    var current = terminalOutputBuffer[sessionID] ?? ""
    current += text
    if current.count > maxTerminalBufferCharacters {
      current = String(current.suffix(maxTerminalBufferCharacters))
    }
    terminalOutputBuffer[sessionID] = current
  }

  private func sendTerminalBuffer(sessionID: String, deviceID: String?) {
    let data = terminalOutputBuffer[sessionID] ?? ""
    send(
      type: "terminal.output", deviceID: deviceID, sessionID: sessionID,
      payload: ["data": data, "buffer": true])
  }

  private func requestPairing() async {
    guard let model else { return }
    do {
      let response: RemotePairingInfo = try await post(
        path: "/api/pairings",
        body: [
          "hostId": model.appSettings.remote.hostID, "token": model.appSettings.remote.hostToken,
        ])
      snapshot.pairing = response
      snapshot.message = "Pairing code: \(response.code)"
    } catch {
      update(status: .failed, message: remoteErrorMessage(error))
    }
  }

  private func loadDevices() async {
    guard let model else { return }
    guard !model.appSettings.remote.hostID.isEmpty, !model.appSettings.remote.hostToken.isEmpty
    else {
      snapshot.devices = []
      return
    }
    guard
      let url = remoteURL(
        path: "/api/hosts/\(model.appSettings.remote.hostID)/devices",
        queryItems: [URLQueryItem(name: "token", value: model.appSettings.remote.hostToken)],
        websocket: false)
    else { return }
    do {
      struct DeviceList: Decodable { var devices: [RemoteHostDevice] }
      let data = try await requestData(url: url)
      let list = try decoder.decode(DeviceList.self, from: data)
      snapshot.devices = list.devices
    } catch {
      snapshot.message = remoteErrorMessage(error)
    }
  }

  private func confirm(pairingID: String) async {
    guard let model else { return }
    do {
      let _: [String: String] = try await post(
        path: "/api/pairings/confirm",
        body: [
          "hostId": model.appSettings.remote.hostID, "token": model.appSettings.remote.hostToken,
          "pairingId": pairingID,
        ])
      snapshot.pendingPairings.removeAll { $0.id == pairingID }
      snapshot.message = "Device paired."
      await loadDevices()
    } catch {
      snapshot.message = remoteErrorMessage(error)
    }
  }

  private func revoke(deviceID: String) async {
    guard let model else { return }
    do {
      let _: [String: Bool] = try await post(
        path: "/api/devices/revoke",
        body: [
          "hostId": model.appSettings.remote.hostID, "token": model.appSettings.remote.hostToken,
          "deviceId": deviceID,
        ])
      await loadDevices()
    } catch {
      snapshot.message = remoteErrorMessage(error)
    }
  }

  private func post<T: Decodable>(path: String, body: Any) async throws -> T {
    guard let url = remoteURL(path: path, queryItems: [], websocket: false) else {
      throw URLError(.badURL)
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await URLSession.shared.data(for: request)
    try validateHTTPResponse(response, data: data)
    do {
      return try decoder.decode(T.self, from: data)
    } catch {
      throw NSError(
        domain: "CoduxRemote", code: -2,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Remote response decode failed: \(error.localizedDescription). Body: \(String(data: data, encoding: .utf8) ?? "<binary>")"
        ])
    }
  }

  private func requestData(url: URL) async throws -> Data {
    let (data, response) = try await URLSession.shared.data(from: url)
    try validateHTTPResponse(response, data: data)
    return data
  }

  private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? "Remote request failed"
      if let error = try? decoder.decode(RemoteErrorResponse.self, from: data) {
        throw NSError(
          domain: "CoduxRemote", code: http.statusCode,
          userInfo: [NSLocalizedDescriptionKey: error.error])
      }
      throw NSError(
        domain: "CoduxRemote", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])
    }
  }

  private func remoteErrorMessage(_ error: Error) -> String {
    error.localizedDescription
  }

  private func send(
    type: String, deviceID: String? = nil, sessionID: String? = nil, payload: [String: Any]
  ) {
    let envelope = RemoteOutgoingEnvelope(
      type: type, deviceID: deviceID, sessionID: sessionID, payload: payload)
    guard let data = try? JSONSerialization.data(withJSONObject: envelope.dictionary),
      let text = String(data: data, encoding: .utf8)
    else { return }
    socket?.send(.string(text)) { _ in }
  }

  private func remoteURL(path: String, queryItems: [URLQueryItem], websocket: Bool) -> URL? {
    guard let model else { return nil }
    var components = URLComponents(
      string: model.appSettings.remote.serverURL.trimmingCharacters(in: .whitespacesAndNewlines))
    components?.path = path
    components?.queryItems = queryItems.isEmpty ? nil : queryItems
    if websocket {
      if components?.scheme == "https" { components?.scheme = "wss" }
      if components?.scheme == "http" { components?.scheme = "ws" }
    }
    return components?.url
  }

  private func update(status: RemoteHostStatus, message: String) {
    snapshot.status = status
    snapshot.message = message
  }

  private func randomToken() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "")
      + UUID().uuidString.replacingOccurrences(of: "-", with: "")
  }
}

private struct RemoteErrorResponse: Decodable {
  var error: String
}

private struct RemoteEnvelope: Decodable {
  var type: String
  var deviceID: String?
  var sessionID: String?
  var payload: [String: Any]?

  enum CodingKeys: String, CodingKey {
    case type
    case deviceID = "deviceId"
    case sessionID = "sessionId"
    case payload
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decode(String.self, forKey: .type)
    deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
    sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
    if let data = try? container.decodeIfPresent(JSONValue.self, forKey: .payload) {
      payload = data.objectValue
    }
  }
}

private struct RemoteOutgoingEnvelope {
  var type: String
  var deviceID: String?
  var sessionID: String?
  var payload: [String: Any]

  var dictionary: [String: Any] {
    var value: [String: Any] = ["type": type, "payload": payload]
    if let deviceID { value["deviceId"] = deviceID }
    if let sessionID { value["sessionId"] = sessionID }
    return value
  }
}

private enum JSONValue: Decodable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: Any])
  case array([Any])
  case null

  var objectValue: [String: Any]? {
    if case .object(let value) = self { return value }
    return nil
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value.mapValues(\.anyValue))
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value.map(\.anyValue))
    } else {
      self = .null
    }
  }

  var anyValue: Any {
    switch self {
    case .string(let value): return value
    case .number(let value): return value
    case .bool(let value): return value
    case .object(let value): return value
    case .array(let value): return value
    case .null: return NSNull()
    }
  }
}
