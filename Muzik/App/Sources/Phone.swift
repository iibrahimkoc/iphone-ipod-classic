import Foundation

/// Finds the iPod on the local network (the phone app publishes _ipodmuzik._tcp over Bonjour)
/// and sends files into its music folder over SSH (key login is set up already).
final class Phone: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var name: String?
    private var host: String?
    private var folder = "/var/mobile/Media/iPodMuzik"
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []

    override init() {
        super.init()
        browser.delegate = self
        browser.searchForServices(ofType: "_ipodmuzik._tcp.", inDomain: "local.")
    }

    var found: Bool { host != nil }

    /// Copies `file` into the iPod's folder as `name`. It is written as a hidden ".part" file
    /// first, so the phone only picks it up once complete (and shows "Müzik alınıyor…" meanwhile).
    func send(_ file: URL, as name: String) async throws {
        guard let host = host else { throw CocoaError(.fileNoSuchFile) }
        let final = "\(folder)/\(name)"
        let part = "\(folder)/.\(name).part"
        let command = "mkdir -p \(quote(folder)) && cat > \(quote(part)) && mv \(quote(part)) \(quote(final))"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                                 "-o", "StrictHostKeyChecking=accept-new", "mobile@\(host)", command]
            do {
                process.standardInput = try FileHandle(forReadingFrom: file)
            } catch {
                continuation.resume(throwing: error)
                return
            }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CocoaError(.fileWriteUnknown))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    private func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Bonjour

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 10)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 == service }
        if services.isEmpty {
            host = nil
            name = nil
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let hostName = sender.hostName else { return }
        host = hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
        if let txt = sender.txtRecordData(),
           let path = NetService.dictionary(fromTXTRecord: txt)["folder"].flatMap({ String(data: $0, encoding: .utf8) }) {
            folder = path
        }
        name = sender.name
    }
}
