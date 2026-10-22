import Foundation

/// Finds the iPod on the local network and sends files into its music folder over SSH (key login
/// is set up already). The phone app publishes _ipodmuzik._tcp over Bonjour, but iOS doesn't
/// always let that through on Wi-Fi, so every address that worked is remembered and probed too.
final class Phone: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var name: String?
    private var host: String?
    private var folder = "/var/mobile/Media/iPodMuzik"
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var probeTimer: Timer?
    private var probing = false

    private var knownHosts: [String] {
        get { UserDefaults.standard.stringArray(forKey: "hosts") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "hosts") }
    }

    override init() {
        super.init()
        browser.delegate = self
        browser.searchForServices(ofType: "_ipodmuzik._tcp.", inDomain: "local.")
        probeTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.probe() }
        probe()
    }

    /// An address typed in by hand (IP or name), tried right away and remembered if it works.
    func add(address: String) {
        let address = address.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return }
        knownHosts = [address] + knownHosts.filter { $0 != address }
        host = nil
        probe()
    }

    /// Tries the remembered addresses over SSH until one answers as the iPod.
    private func probe() {
        guard !probing else { return }
        let candidates = host.map { [$0] } ?? knownHosts
        guard !candidates.isEmpty else { return }
        probing = true
        DispatchQueue.global().async {
            var found: (host: String, name: String)?
            for candidate in candidates {
                if let name = Self.check(candidate) {
                    found = (candidate, name)
                    break
                }
            }
            DispatchQueue.main.async {
                self.probing = false
                if let found = found {
                    self.remember(found.host)
                    self.host = found.host
                    self.name = self.name ?? found.name
                } else {
                    self.host = nil
                    self.name = nil
                }
            }
        }
    }

    /// The phone's name if `host` is reachable and has the iPod folder.
    private static func check(_ host: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "-o", "StrictHostKeyChecking=accept-new",
                             "mobile@\(host)", "test -d /var/mobile/Media/iPodMuzik && hostname"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let name = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : host
    }

    private func remember(_ host: String) {
        knownHosts = [host] + knownHosts.filter { $0 != host }
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
        remember(host!)
        if let txt = sender.txtRecordData(),
           let path = NetService.dictionary(fromTXTRecord: txt)["folder"].flatMap({ String(data: $0, encoding: .utf8) }) {
            folder = path
        }
        name = sender.name
    }
}
