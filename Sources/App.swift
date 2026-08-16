import SwiftUI
import AVFoundation
import CoreHaptics
import CoreMotion
import Photos

@main
struct CycloramicApp: App {
    var body: some Scene {
        WindowGroup { MenuView().preferredColorScheme(.dark) }
    }
}

// MARK: - Modely
struct DeviceModel: Identifiable {
    let id = UUID()
    let name: String
    let status: Status
    let tip: String
    enum Status: String {
        case ok = "✓ Podporováno"
        case partial = "~ Částečně"
        case no = "✗ Nepodporováno"
        var color: Color {
            switch self { case .ok: return .green; case .partial: return .orange; case .no: return .red }
        }
    }
}

let models = [
    DeviceModel(name: "iPhone 5", status: .ok, tip: "Postav telefon na hranu na hladký lesklý povrch (sklo, leštěný stůl)."),
    DeviceModel(name: "iPhone 5s", status: .ok, tip: "Postav telefon na hranu na hladký lesklý povrch."),
    DeviceModel(name: "iPhone SE (1. gen.)", status: .ok, tip: "Máš poslední iPhone, který se umí otočit! Postav ho na hranu na sklo."),
    DeviceModel(name: "iPhone 6 / 6 Plus", status: .partial, tip: "Zaoblené hrany – opři telefon o nabíječku jako podstavec."),
    DeviceModel(name: "iPhone 6s / 6s Plus", status: .partial, tip: "Slabší Taptic Engine – otáčení je omezené."),
    DeviceModel(name: "iPhone 7 a novější", status: .no, tip: "Taptic Engine + zaoblené hrany – neotočí se."),
]

// MARK: - Menu
struct MenuView: View {
    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(models) { m in
                        if m.status == .no {
                            ModelRow(model: m).opacity(0.45)
                        } else {
                            NavigationLink(destination: RotationView(model: m)) { ModelRow(model: m) }
                        }
                    }
                } header: {
                    Text("Vyber model")
                } footer: {
                    Text("Otáčení vibrací funguje jen na telefonech s klasickým vibračním motorkem a plochými hranami.")
                }
            }
            .navigationTitle("📱 Cycloramic")
        }
    }
}

struct ModelRow: View {
    let model: DeviceModel
    var body: some View {
        HStack {
            Text(model.name)
            Spacer()
            Text(model.status.rawValue)
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(model.status.color.opacity(0.15))
                .foregroundColor(model.status.color)
                .cornerRadius(8)
        }
    }
}

// MARK: - Vibrace (SE 1 nepodporuje Core Haptics → klasický motorek)
final class HapticMotor {
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private var legacyTimer: Timer?

    func test() {
        if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
                .init(parameterID: .hapticIntensity, value: 1),
                .init(parameterID: .hapticSharpness, value: 1)
            ], relativeTime: 0)
            if let e = try? CHHapticEngine(),
               let pattern = try? CHHapticPattern(events: [event], parameters: []),
               let p = try? e.makePlayer(with: pattern) {
                try? e.start(); try? p.start(atTime: 0)
            }
        } else {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }

    func startContinuous() {
        if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            do {
                engine = try CHHapticEngine()
                engine?.isAutoShutdownEnabled = false
                try engine?.start()
                let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    .init(parameterID: .hapticIntensity, value: 1),
                    .init(parameterID: .hapticSharpness, value: 0.5)
                ], relativeTime: 0, duration: 1)
                let pattern = try CHHapticPattern(events: [event], parameters: [])
                let p = try engine?.makeAdvancedPlayer(with: pattern)
                p?.loopEnabled = true
                player = p
                try p?.start(atTime: 0)
            } catch { print("Haptics: \(error)") }
        } else {
            // iPhone SE 1: smyčka klasického vibračního motorku
            legacyTimer?.invalidate()
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            legacyTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }
        }
    }

    func stop() {
        legacyTimer?.invalidate(); legacyTimer = nil
        try? player?.stop(atTime: 0); player = nil
        engine = nil
    }
}

// MARK: - Gyroskop (měří skutečnou rotaci)
final class GyroMeter: ObservableObject {
    @Published var degrees: Double = 0
    private let motion = CMMotionManager()
    private var lastYaw: Double?

    func start() {
        degrees = 0; lastYaw = nil
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] dm, _ in
            guard let self = self, let yaw = dm?.attitude.yaw else { return }
            if let l = self.lastYaw {
                var d = yaw - l
                if d > .pi { d -= 2 * .pi }
                if d < -.pi { d += 2 * .pi }
                self.degrees += abs(d * 180 / .pi)
            }
            self.lastYaw = yaw
        }
    }
    func stop() { motion.stopDeviceMotionUpdates() }
}

// MARK: - Kamera (panorama)
final class CameraCapturer: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    @Published var frames: [UIImage] = []
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var configured = false

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                if !self.configured {
                    self.session.beginConfiguration()
                    self.session.sessionPreset = .photo
                    if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                       let input = try? AVCaptureDeviceInput(device: device),
                       self.session.canAddInput(input), self.session.canAddOutput(self.output) {
                        self.session.addInput(input)
                        self.session.addOutput(self.output)
                    }
                    self.session.commitConfiguration()
                    self.configured = true
                }
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func snap() {
        guard session.isRunning else { return }
        output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    func stop() {
        if session.isRunning {
            DispatchQueue.global().async { self.session.stopRunning() }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(), let img = UIImage(data: data) else { return }
        let thumb = img.preparingThumbnail(of: CGSize(width: 240, height: 240)) ?? img
        DispatchQueue.main.async { self.frames.append(thumb) }
    }
}

// MARK: - Rotace
struct RotationView: View {
    let model: DeviceModel

    @StateObject private var gyro = GyroMeter()
    @StateObject private var cam = CameraCapturer()
    private let haptics = HapticMotor()

    @State private var duration: Double = 15
    @State private var useCamera = false
    @State private var running = false
    @State private var angle: Double = 0
    @State private var startDate = Date()
    @State private var timer: Timer?
    @State private var shotsTaken = 0
    @State private var countdown = 0
    @State private var saved = false

    private let totalShots = 12

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("💡 " + model.tip)
                    .font(.footnote).foregroundColor(.secondary).padding(.horizontal)

                ZStack {
                    VStack { Spacer(); Rectangle().fill(Color.white.opacity(0.15)).frame(height: 2) }
                        .padding(.horizontal, 30).padding(.bottom, 46)
                    RoundedRectangle(cornerRadius: 22)
                        .fill(LinearGradient(colors: [Color(white: 0.25), Color(white: 0.1)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 110, height: 224)
                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.25), lineWidth: 2))
                        .overlay(Circle().fill(Color.blue).frame(width: 10).offset(y: -86))
                        .rotationEffect(.degrees(angle))
                        .shadow(color: .black.opacity(0.6), radius: 12, y: 10)
                }
                .frame(height: 300)

                HStack {
                    Label("Cíl \(Int(angle))°", systemImage: "rotate.right")
                    Spacer()
                    Label("Skutečně \(Int(gyro.degrees))°", systemImage: "gyroscope")
                }
                .font(.headline).padding(.horizontal)

                if countdown > 0 {
                    Text("Start za \(countdown)… postav telefon na hranu!")
                        .font(.title3).foregroundColor(.orange)
                }

                if !running {
                    Picker("Délka rotace", selection: $duration) {
                        Text("10 s").tag(10.0)
                        Text("15 s").tag(15.0)
                        Text("20 s").tag(20.0)
                    }
                    .pickerStyle(.segmented).padding(.horizontal)

                    Toggle("📷 Snímat panorama kamerou", isOn: $useCamera).padding(.horizontal)
                }

                VStack(spacing: 10) {
                    Button {
                        if running { stop() } else { start() }
                    } label: {
                        Text(running ? "⏹ Zastavit" : "▶ Spustit rotaci 360°")
                            .font(.headline).frame(maxWidth: .infinity).padding()
                            .background(running ? Color.red : Color.blue)
                            .foregroundColor(.white).cornerRadius(12)
                    }
                    if !running {
                        Button("📳 Vyzkoušet vibraci") { haptics.test() }
                            .frame(maxWidth: .infinity).padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                    }
                }
                .padding(.horizontal)

                if !cam.frames.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("📸 Pořízené snímky (\(cam.frames.count))").font(.subheadline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(Array(cam.frames.enumerated()), id: \.offset) { _, img in
                                    Image(uiImage: img).resizable().scaledToFit()
                                        .frame(height: 70).cornerRadius(6)
                                }
                            }
                        }
                        Button("💾 Uložit vše do Fotek", action: saveAll).font(.subheadline)
                        if saved { Text("✅ Uloženo").foregroundColor(.green).font(.caption) }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(model.name)
        .onDisappear { stop() }
    }

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        countdown = 3
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            countdown -= 1
            if countdown <= 0 { t.invalidate(); beginRotation() }
        }
    }

    func beginRotation() {
        running = true
        angle = 0; shotsTaken = 0; saved = false
        cam.frames.removeAll()
        gyro.start()
        haptics.startContinuous()
        if useCamera { cam.start() }
        startDate = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in tick() }
    }

    func tick() {
        let p = min(Date().timeIntervalSince(startDate) / duration, 1)
        angle = p * 360
        if useCamera, p < 1 {
            let due = Int(p * Double(totalShots))
            if due > shotsTaken { shotsTaken = due; cam.snap() }
        }
        if p >= 1 { stop(); haptics.test() }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        haptics.stop()
        gyro.stop()
        cam.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        running = false
    }

    func saveAll() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else { return }
            let imgs = self.cam.frames
            PHPhotoLibrary.shared().performChanges {
                for img in imgs { PHAssetChangeRequest.creationRequestForAsset(from: img) }
            } completionHandler: { ok, _ in
                DispatchQueue.main.async { self.saved = ok }
            }
        }
    }
}
