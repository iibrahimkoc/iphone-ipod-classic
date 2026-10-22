import SwiftUI
import AVFoundation
import Photos
import os

private let log = Logger(subsystem: "com.ibrahimkoc.clickwheel", category: "camera")

/// The camera on the iPod screen, like the iPod nano's: the center button takes a photo, the wheel
/// zooms and ⏯ switches between the back and front cameras. Photos go to the Camera Roll.
///
/// Taking photos needs the iokit-user-client-class entitlement (see entitlements.plist): without
/// it the app can't open IOSurfaces, so mediaserverd takes the photo but it never arrives.
final class CameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var front = false
    /// Goes up with every photo, for the white flash on screen.
    @Published private(set) var shots = 0
    @Published private(set) var message: String?
    /// Width / height of the preview on screen; photos are cropped to it, so they hold what was seen.
    var visibleAspect: CGFloat = 4 / 3

    /// Session work is slow, so it stays off the main thread.
    private let queue = DispatchQueue(label: "com.ibrahimkoc.clickwheel.camera")
    private let output = AVCapturePhotoOutput()
    private var input: AVCaptureDeviceInput?
    private var configured = false
    private var hideMessage: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session,
                                                                queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            log.error("session error: \(String(describing: error), privacy: .public)")
            DispatchQueue.main.async { self?.show("Kamera hatası") }
        })
    }

    static let maxZoom: CGFloat = 5

    func start() {
        zoom = 1
        log.notice("start, access status \(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
        AVCaptureDevice.requestAccess(for: .video) { granted in
            log.notice("access granted: \(granted)")
            guard granted else { return DispatchQueue.main.async { self.show("Kamera izni yok") } }
            self.queue.async {
                if !self.configured {
                    self.session.beginConfiguration()
                    self.session.sessionPreset = .photo
                    if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
                    self.output.isHighResolutionCaptureEnabled = true
                    self.useCamera(front: false)
                    self.session.commitConfiguration()
                    self.configured = true
                }
                if !self.session.isRunning { self.session.startRunning() }
                log.notice("running: \(self.session.isRunning), input: \(self.input != nil)")
                if !self.session.isRunning || self.input == nil {
                    DispatchQueue.main.async { self.show("Kamera açılamadı") }
                }
            }
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    func flip() {
        front.toggle()
        zoom = 1
        let front = self.front
        queue.async {
            self.session.beginConfiguration()
            self.useCamera(front: front)
            self.session.commitConfiguration()
        }
    }

    /// One wheel tick is a tenth of the way from 1× to 5×.
    func zoom(by delta: Int) -> Bool {
        let new = min(max(zoom + CGFloat(delta) * 0.4, 1), Self.maxZoom)
        guard new != zoom else { return false }
        zoom = new
        queue.async {
            guard let device = self.input?.device, (try? device.lockForConfiguration()) != nil else { return }
            device.videoZoomFactor = min(new, device.activeFormat.videoMaxZoomFactor)
            device.unlockForConfiguration()
        }
        return true
    }

    func capture() {
        shots += 1
        queue.async {
            guard self.session.isRunning else {
                log.error("capture while not running")
                return DispatchQueue.main.async { self.show("Kamera açılamadı") }
            }
            self.output.connection(with: .video)?.videoOrientation = .portrait
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.isHighResolutionPhotoEnabled = true
            log.notice("capturing")
            // The system plays the shutter sound.
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    private func useCamera(front: Bool) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back),
              let new = try? AVCaptureDeviceInput(device: device) else {
            log.error("no camera device (front: \(front))")
            return
        }
        if let old = input { session.removeInput(old) }
        if session.canAddInput(new) {
            session.addInput(new)
            input = new
        } else if let old = input, session.canAddInput(old) {
            session.addInput(old)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        log.notice("photo done, error: \(String(describing: error), privacy: .public)")
        guard error == nil, let full = photo.fileDataRepresentation().flatMap(UIImage.init(data:)),
              let data = Self.crop(full, toAspect: visibleAspect, mirrored: input?.device.position == .front)
                .jpegData(compressionQuality: 0.92) else {
            return DispatchQueue.main.async { self.show("Çekilemedi") }
        }
        save(data)
    }

    /// The middle of `image` at the preview's aspect ratio, which is what the preview shows
    /// (it fills the screen and cuts off the rest). The front camera's preview is a mirror image,
    /// so its photos are mirrored too.
    private static func crop(_ image: UIImage, toAspect aspect: CGFloat, mirrored: Bool) -> UIImage {
        let size = image.size
        var crop = size
        if size.width / size.height < aspect {
            crop.height = (size.width / aspect).rounded()
        } else {
            crop.width = (size.height * aspect).rounded()
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: crop, format: format).image { context in
            if mirrored {
                context.cgContext.translateBy(x: crop.width, y: 0)
                context.cgContext.scaleBy(x: -1, y: 1)
            }
            image.draw(at: CGPoint(x: (crop.width - size.width) / 2, y: (crop.height - size.height) / 2))
        }
    }

    private func save(_ data: Data) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            log.notice("photos add status \(status.rawValue)")
            guard status == .authorized || status == .limited else {
                return DispatchQueue.main.async { self.show("Fotoğraflar izni yok") }
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }) { saved, error in
                log.notice("saved: \(saved), error: \(String(describing: error), privacy: .public)")
                DispatchQueue.main.async { self.show(saved ? "Kaydedildi" : "Kaydedilemedi") }
            }
        }
    }

    private func show(_ text: String) {
        message = text
        hideMessage?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.message = nil }
        hideMessage = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

/// The Camera Roll, newest first, for "Fotoğraflar".
final class PhotoLibrary: ObservableObject {
    @Published private(set) var assets: [PHAsset] = []
    @Published private(set) var denied = false
    private let manager = PHCachingImageManager()

    /// Reloads the list; `done` runs on the main thread once it is in.
    func load(done: (() -> Void)? = nil) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            let allowed = status == .authorized || status == .limited
            var assets: [PHAsset] = []
            if allowed {
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, _ in assets.append(asset) }
            }
            DispatchQueue.main.async {
                self.denied = !allowed
                self.assets = assets
                self.shown = nil
                self.shownIndex = min(self.shownIndex ?? 0, max(assets.count - 1, 0))
                done?()
            }
        }
    }

    // MARK: Actions (held center button)

    func toggleFavorite(_ index: Int) {
        guard assets.indices.contains(index) else { return }
        let asset = assets[index], favorite = !asset.isFavorite
        PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest(for: asset).isFavorite = favorite }) { saved, _ in
            if saved { self.load() }
        }
    }

    /// iOS asks for confirmation itself before the photo goes to Recently Deleted.
    func delete(_ index: Int, done: @escaping (Bool) -> Void) {
        guard assets.indices.contains(index) else { return done(false) }
        let asset = assets[index]
        PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest.deleteAssets([asset] as NSArray) }) { deleted, _ in
            DispatchQueue.main.async {
                guard deleted else { return done(false) }
                self.load { done(true) }
            }
        }
    }

    /// The photo on screen. Only the newest request counts: an older one still loading is
    /// cancelled, and anything it delivers late is ignored, so fast scrolling can't show the wrong photo.
    @Published private(set) var image: UIImage?
    private var shown: Int?
    private var request: PHImageRequestID?
    /// The index last asked for, kept when the list is reloaded.
    private(set) var shownIndex: Int?

    func show(_ index: Int, size: CGSize) {
        guard index != shown || image == nil else { return }
        shown = index
        shownIndex = index
        image = nil
        if let request = request { manager.cancelImageRequest(request) }
        guard assets.indices.contains(index) else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = false
        request = manager.requestImage(for: assets[index], targetSize: size, contentMode: .aspectFit, options: options) {
            [weak self] image, _ in
            DispatchQueue.main.async {
                guard let self = self, self.shown == index else { return }
                self.image = image
            }
        }
    }
}

struct CameraView: View {
    @ObservedObject var camera: CameraController
    @State private var flash = false

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack {
                Color.black
                CameraPreview(session: camera.session)
                Color.white.opacity(flash ? 0.9 : 0)
                VStack {
                    HStack {
                        if camera.zoom > 1 { label(String(format: "%.1f×", camera.zoom), h: h) }
                        Spacer()
                        label(camera.front ? "Ön" : "Arka", h: h)
                    }
                    Spacer()
                    if let message = camera.message { label(message, h: h) }
                }
                .padding(6)
            }
            .clipped()
            .onAppear { camera.visibleAspect = geo.size.width / geo.size.height }
        }
        .onChange(of: camera.shots) { _ in
            flash = true
            withAnimation(.easeOut(duration: 0.3)) { flash = false }
        }
    }

    private func label(_ text: String, h: CGFloat) -> some View {
        Text(text)
            .font(.system(size: h * 0.07, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// One photo at a time; the wheel moves through them.
struct PhotoView: View {
    @ObservedObject var photos: PhotoLibrary
    let index: Int

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack {
                Color.black
                if photos.assets.isEmpty {
                    Text(photos.denied ? "Fotoğraflar izni yok" : "Fotoğraf yok")
                        .font(.system(size: h * 0.08))
                        .foregroundColor(.gray)
                } else {
                    if let image = photos.image {
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                    VStack {
                        if photos.assets.indices.contains(index), photos.assets[index].isFavorite {
                            HStack {
                                Spacer()
                                Image(systemName: "heart.fill")
                                    .font(.system(size: h * 0.07))
                                    .foregroundColor(.white)
                                    .shadow(radius: 2)
                            }
                        }
                        Spacer()
                        Text("\(index + 1) / \(photos.assets.count)")
                            .font(.system(size: h * 0.06, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .background(Color.black.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .padding(6)
                }
            }
            // onChange's closure still sees the view from before the change, so the new index is
            // passed in rather than read from `index`.
            .onAppear { load(index, size: geo.size) }
            .onChange(of: index) { new in load(new, size: geo.size) }
            .onChange(of: photos.assets.count) { _ in load(photos.shownIndex ?? 0, size: geo.size) }
        }
    }

    private func load(_ index: Int, size: CGSize) {
        let scale = UIScreen.main.scale
        photos.show(index, size: CGSize(width: size.width * scale, height: size.height * scale))
    }
}
