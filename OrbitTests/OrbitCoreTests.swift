import Testing
@testable import Orbit

@Suite("OrbitCore")
struct OrbitCoreTests {
    @Test("module marker is accessible")
    func moduleMarker() {
        #expect(OrbitCore.version == "0.1.0")
    }
}
