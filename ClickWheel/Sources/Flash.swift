import UIKit
import WebKit

/// What the game screen and the wheel need from a running game, whether a libretro core runs it
/// (Emulator) or Ruffle in a web view (FlashGame).
protocol GameSession: AnyObject {
    var view: UIView { get }
    var console: Console { get }
    var title: String { get }
    /// The picture's width over its height.
    var aspect: CGFloat { get }
    /// Held buttons as a bit per RETRO_DEVICE_ID_JOYPAD_* id: the wheel's, and the screen taps'.
    var pad: UInt32 { get set }
    var tapped: UInt32 { get set }
    /// The game asked to quit; called on the main queue.
    var onExit: (() -> Void)? { get set }
    func stop()
}

extension Emulator: GameSession {}

/// A Flash game (.swf) played by Ruffle (build.sh bundles its web build in the app's ruffle
/// folder) in a web view. The page, Ruffle and the game come from the ipod-flash: scheme, so
/// Ruffle can fetch its .wasm. The wheel's buttons become arrow keys and the space bar; the
/// screen takes touches as the mouse, and a long press on it leaves.
final class FlashGame: NSObject, GameSession, WKScriptMessageHandler, UIGestureRecognizerDelegate {

    let console: Console
    let title: String
    let aspect: CGFloat = 4.0 / 3.0
    var onExit: (() -> Void)?
    var pad: UInt32 = 0 { didSet { sendKeys() } }
    var tapped: UInt32 = 0 { didSet { sendKeys() } }
    var view: UIView { web }

    private let game: URL
    private var web: WKWebView!
    /// The buttons the page was last told are down.
    private var held: UInt32 = 0

    /// A button's keys, as the page's KeyboardEvent key and code. The center is both the space bar
    /// and the semicolon, the first player's action key in two-player games like Playing With Fire 2.
    private static let keys: [Int32: [(key: String, code: String)]] = [
        RETRO_DEVICE_ID_JOYPAD_UP: [("ArrowUp", "ArrowUp")],
        RETRO_DEVICE_ID_JOYPAD_DOWN: [("ArrowDown", "ArrowDown")],
        RETRO_DEVICE_ID_JOYPAD_LEFT: [("ArrowLeft", "ArrowLeft")],
        RETRO_DEVICE_ID_JOYPAD_RIGHT: [("ArrowRight", "ArrowRight")],
        RETRO_DEVICE_ID_JOYPAD_A: [(" ", "Space"), (";", "Semicolon")],
        RETRO_DEVICE_ID_JOYPAD_START: [("Enter", "Enter")],
    ]

    fileprivate static let page = """
    <!doctype html>
    <html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
    <style>
    html, body { margin: 0; height: 100%; background: #000; overflow: hidden; -webkit-user-select: none; -webkit-touch-callout: none; }
    ruffle-player { display: block; width: 100%; height: 100%; }
    </style>
    <script>
    for (const level of ["log", "warn", "error"]) {
        const original = console[level];
        console[level] = (...args) => { webkit.messageHandlers.log.postMessage(level + ": " + args.join(" ")); original(...args); };
    }
    window.addEventListener("error", e => webkit.messageHandlers.log.postMessage("error: " + e.message));
    window.RufflePlayer = { config: {
        publicPath: "/ruffle/", autoplay: "on", unmuteOverlay: "hidden", splashScreen: false,
        letterbox: "on", contextMenu: "off", showSwfDownload: false, openUrlMode: "deny",
        allowScriptAccess: false, backgroundColor: "#000000", logLevel: "warn",
        // wgpu over WebGL draws nothing in iOS 15's web view, and the canvas one stutters.
        preferredRenderer: "webgl",
        // Ruffle picks low on phones, which blurs the picture.
        quality: "high",
    } };
    </script>
    <script src="/ruffle/ruffle.js"></script>
    </head><body><script>
    const player = window.RufflePlayer.newest().createPlayer();
    document.body.appendChild(player);
    (player.ruffle ? player.ruffle() : player).load({ url: "/game.swf" });
    // Ruffle focuses a hidden text field for its on-screen keyboard; the wheel is the keyboard
    // here, so the field keeps the focus (Ruffle takes keys only while it has it) but shows nothing.
    function quiet(field) { field.inputMode = "none"; field.readOnly = true; }
    player.shadowRoot.querySelectorAll("input, textarea").forEach(quiet);
    player.shadowRoot.addEventListener("focusin", e => {
        if (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA") quiet(e.target);
    }, true);
    player.focus();
    function key(type, key, code) {
        // Ruffle takes keys only after its focusin, which a wheel never causes; it ignores the
        // event while it has focus, so each element is told (only the one that listens hears it).
        for (const element of [player, ...player.shadowRoot.querySelectorAll("*")]) {
            element.dispatchEvent(new FocusEvent("focusin"));
        }
        player.dispatchEvent(new KeyboardEvent(type, { key, code, bubbles: true, cancelable: true }));
    }
    </script></body></html>
    """

    init(console: Console, game: URL) {
        self.console = console
        self.game = game
        title = console.title(game)
        super.init()

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(FlashFiles(game: game), forURLScheme: FlashFiles.scheme)
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsInlineMediaPlayback = true
        // The handlers hold the game; stop() removes them.
        configuration.userContentController.add(self, name: "log")
        web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never

        let leave = UILongPressGestureRecognizer(target: self, action: #selector(longPress))
        leave.minimumPressDuration = 0.8
        leave.cancelsTouchesInView = false
        leave.delegate = self
        web.addGestureRecognizer(leave)

        web.load(URLRequest(url: URL(string: "\(FlashFiles.scheme)://game/index.html")!))
    }

    func stop() {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "log")
        web.stopLoading()
        web.loadHTMLString("", baseURL: nil)
    }

    @objc private func longPress(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began { onExit?() }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    /// Tells the page about each button that went down or up since last time.
    private func sendKeys() {
        let now = pad | tapped
        let changed = now ^ held
        guard changed != 0 else { return }
        held = now
        var script = ""
        for (id, keys) in Self.keys where changed & (1 << UInt32(id)) != 0 {
            let type = now & (1 << UInt32(id)) != 0 ? "keydown" : "keyup"
            for key in keys { script += "key('\(type)', '\(key.key)', '\(key.code)');" }
        }
        if !script.isEmpty { web.evaluateJavaScript(script) }
    }

    // MARK: Messages

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let line = String(describing: message.body)
        NSLog("[Flash] %@", line)
        // Also kept next to the games, as the phone has no log reader over Wi-Fi.
        let log = console.folder.appendingPathComponent(".flash.log")
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        } else {
            try? Data((line + "\n").utf8).write(to: log)
        }
    }
}

/// Serves the ipod-flash: scheme: the page, Ruffle from the app's bundle and the game file.
private final class FlashFiles: NSObject, WKURLSchemeHandler {
    static let scheme = "ipod-flash"
    private let game: URL

    init(game: URL) {
        self.game = game
    }


    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let file: URL
        switch url.path {
        case "/index.html":
            respond(task, url: url, data: Data(FlashGame.page.utf8), type: "text/html")
            return
        case "/game.swf":
            file = game
        default:
            guard url.path.hasPrefix("/ruffle/"), !url.path.contains("..") else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            file = URL(fileURLWithPath: Bundle.main.bundlePath + url.path)
        }
        guard let data = try? Data(contentsOf: file) else {
            NSLog("[Flash] missing %@", url.path)
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let types = ["js": "text/javascript", "wasm": "application/wasm", "swf": "application/x-shockwave-flash"]
        respond(task, url: url, data: data, type: types[file.pathExtension.lowercased()] ?? "application/octet-stream")
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, type: String) {
        let headers = ["Content-Type": type, "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*"]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}
