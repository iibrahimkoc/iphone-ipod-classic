import SwiftUI
import AVFoundation
import Photos

/// The camera on the iPod screen, like the iPod nano's: the center button takes a photo, the wheel
/// zooms and ⏯ switches between the back and front cameras. Photos go to the Camera Roll.
final class CameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var front = false
    /// Goes up with every photo, for the white flash on screen.
    @Published private(set) var shots = 0
    @Published private(set) var message: String?

    /// Session work is slow, so it stays off the main thread.
    private let queue = DispatchQueue(label: "com.ibrahimkoc.clickwheel.camera")
    private let output = AVCapturePhotoOutput()
    private var input: AVCaptureDeviceInput?
    private var configured = false
    private var hideMessage: DispatchWorkItem?

    static let maxZoom: CGFloat = 5

    func start() {
        zoom = 1
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { return DispatchQueue.main.async { self.show("Kamera izni yok") } }
            self.queue.async {
                if !self.configured {
                    self.session.beginConfiguration()
                    self.session.sessionPreset = .photo
                    if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
                    self.useCamera(front: false)
                    self.session.commitConfiguration()
                    self.configured = true
                }
                if !self.session.isRunning { self.session.startRunning() }
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
            guard self.session.isRunning else { return }
            self.output.connection(with: .video)?.videoOrientation = .portrait
            // The system plays the shutter sound.
            self.output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    private func useCamera(front: Bool) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back),
              let new = try? AVCaptureDeviceInput(device: device) else { return }
        if let old = input { session.removeInput(old) }
        if session.canAddInput(new) {
            session.addInput(new)
            input = new
        } else if let old = input, session.canAddInput(old) {
            session.addInput(old)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            return DispatchQueue.main.async { self.show("Çekilemedi") }
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                return DispatchQueue.main.async { self.show("Fotoğraflar izni yok") }
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }) { saved, _ in
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

    func load() {
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
            }
        }
    }

    func image(at index: Int, size: CGSize, done: @escaping (UIImage?) -> Void) {
        guard assets.indices.contains(index) else { return done(nil) }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = false
        manager.requestImage(for: assets[index], targetSize: size, contentMode: .aspectFit, options: options) { image, _ in
            done(image)
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
    @State private var image: UIImage?

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
                    if let image = image {
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                    VStack {
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
            .onAppear { load(size: geo.size) }
            .onChange(of: index) { _ in load(size: geo.size) }
            .onChange(of: photos.assets.count) { _ in load(size: geo.size) }
        }
    }

    private func load(size: CGSize) {
        let wanted = index
        let scale = UIScreen.main.scale
        photos.image(at: wanted, size: CGSize(width: size.width * scale, height: size.height * scale)) { image in
            // A slow request for a photo already scrolled past mustn't replace the current one.
            guard wanted == index else { return }
            self.image = image
        }
    }
}
