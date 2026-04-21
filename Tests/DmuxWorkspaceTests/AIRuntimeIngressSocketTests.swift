import Darwin
import XCTest
@testable import DmuxWorkspace

@MainActor
final class AIRuntimeIngressSocketTests: XCTestCase {
    private let ingress = AIRuntimeIngressService.shared
    private let bridge = AIRuntimeBridgeService()

    func testRestartKeepsRuntimeSocketConnectable() async throws {
        let socketPath = bridge.runtimeEventSocketURL().path

        ingress.startWatching()
        ingress.startWatching()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(canConnect(to: socketPath), "runtime socket should remain connectable after restart")
    }

    private func canConnect(to socketPath: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return false
        }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        let utf8 = socketPath.utf8CString
        guard utf8.count < maxLength else {
            return false
        }

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: CChar.self, repeating: 0)
            for (index, byte) in utf8.enumerated() {
                buffer[index] = UInt8(bitPattern: byte)
            }
        }

        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + utf8.count)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                connect(fd, pointer, addressLength)
            }
        }
        return result == 0
    }
}
