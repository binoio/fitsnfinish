import SwiftUI
import UniformTypeIdentifiers
import FitsnFinishCore

extension UTType {
    static var fits: UTType {
        UTType(filenameExtension: "fits") ?? .data
    }
}

@main
struct FitsnFinishApp: App {
    @StateObject private var model = DocumentModel()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif
    #if os(macOS) && canImport(Sparkle)
    @StateObject private var updater = UpdaterModel()
    #endif

    var body: some Scene {
        WindowGroup("FITS n' Finish") {
            ContentView()
                .environmentObject(model)
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 600)
                #endif
        }
        .commands {
            #if os(macOS) && canImport(Sparkle)
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            #endif
            CommandGroup(replacing: .newItem) {
                Button("Open FITS…") { model.isImporterPresented = true }
                    .keyboardShortcut("o")
                Button("Export Processed FITS…") { model.isExporterPresented = true }
                    .keyboardShortcut("e")
                    .disabled(model.processed == nil)
            }
            CommandGroup(after: .undoRedo) {
                Button("Undo Processing Step") { model.undo() }
                    .keyboardShortcut("z", modifiers: [.command, .option])
                    .disabled(!model.canUndo)
                Button("Redo Processing Step") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .option, .shift])
                    .disabled(!model.canRedo)
            }
        }
    }
}

/// Wraps exported FITS bytes for the SwiftUI file exporter.
struct FITSDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.fits, .data] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: DocumentModel
    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        layout
            .navigationTitle(model.fileName ?? "FITS n' Finish")
            .fileImporter(
                isPresented: $model.isImporterPresented,
                allowedContentTypes: [.fits, .data]
            ) { result in
                if case .success(let url) = result {
                    model.open(url: url)
                }
            }
            .fileExporter(
                isPresented: $model.isExporterPresented,
                document: model.exportDocument,
                contentType: .fits,
                defaultFilename: model.exportFileName
            ) { result in
                switch result {
                case .success(let url):
                    model.statusMessage = "Exported \(url.lastPathComponent)"
                case .failure(let error):
                    model.statusMessage = "Export failed: \(error.localizedDescription)"
                }
            }
    }

    @ViewBuilder
    private var layout: some View {
        #if os(macOS)
        HSplitView {
            imagePane
                .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
            ControlsView()
                .frame(width: 320)
        }
        #else
        if horizontalSizeClass == .regular {
            HStack(spacing: 0) {
                imagePane.frame(maxWidth: .infinity, maxHeight: .infinity)
                ControlsView().frame(width: 340)
            }
        } else {
            VStack(spacing: 0) {
                imagePane.frame(maxWidth: .infinity, minHeight: 240)
                ControlsView()
            }
        }
        #endif
    }

    @ViewBuilder
    private var imagePane: some View {
        if let display = model.displayPlanes, let size = model.imageSize {
            MetalView(planes: display, width: size.width, height: size.height,
                      midtone: model.previewMidtone)
        } else {
            ContentUnavailableView {
                Label("No Image", systemImage: "moon.stars")
            } description: {
                Text("Open a 16-bit FITS frame to begin.")
            } actions: {
                Button("Open FITS…") { model.isImporterPresented = true }
            }
        }
    }
}

/// Observable session state: the loaded frame, telemetry, tuning parameters,
/// and the processed result.
@MainActor
final class DocumentModel: ObservableObject {
    @Published var fileName: String?
    @Published var original: FITSImage?
    /// Processed channel planes, matching `original.planes` in order.
    @Published var processed: [[Float]]?
    @Published var showOriginal = false
    @Published var isProcessing = false
    @Published var statusMessage = "Ready"
    @Published var isImporterPresented = false
    @Published var isExporterPresented = false

    // Session-scoped processing history. Entries hold copy-on-write
    // references to run outputs (no pixel copying); entry 0 is always the
    // untouched original and survives trimming.
    private struct HistoryEntry {
        let planes: [[Float]]?
        let label: String
    }
    private var history: [HistoryEntry] = [HistoryEntry(planes: nil, label: "Original")]
    @Published private(set) var historyIndex = 0
    private static let historyLimit = 8

    @Published var telemetry = TelemetrySnapshot()
    @Published var degree: PolynomialFitter.Degree = .linear
    @Published var physicsStrength: Float = 1.0
    @Published var previewMidtone: Float = 0.15
    @Published var useLiveTelemetry = false

    private let subtractEngine = MetalSubtractEngine()

    var imageSize: (width: Int, height: Int)? {
        original.map { ($0.width, $0.height) }
    }

    var displayPlanes: [[Float]]? {
        showOriginal ? original?.planes : (processed ?? original?.planes)
    }

    var exportDocument: FITSDocument? {
        guard let processed, let size = imageSize else { return nil }
        return FITSDocument(
            data: FITSWriter.data(planes: processed, width: size.width, height: size.height)
        )
    }

    var canUndo: Bool { historyIndex > 0 }
    var canRedo: Bool { historyIndex < history.count - 1 }

    func undo() {
        guard canUndo else { return }
        historyIndex -= 1
        processed = history[historyIndex].planes
        statusMessage = "Undid to: \(history[historyIndex].label)"
    }

    func redo() {
        guard canRedo else { return }
        historyIndex += 1
        processed = history[historyIndex].planes
        statusMessage = "Redid to: \(history[historyIndex].label)"
    }

    private func recordRun(_ planes: [[Float]], label: String) {
        if historyIndex + 1 < history.count {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(HistoryEntry(planes: planes, label: label))
        // Trim oldest runs but never the original baseline.
        while history.count > Self.historyLimit {
            history.remove(at: 1)
        }
        historyIndex = history.count - 1
        processed = planes
    }

    var exportFileName: String {
        (fileName as NSString?)?
            .deletingPathExtension.appending("_finished") ?? "finished"
    }

    // MARK: File handling

    func open(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let image = try FITSReader.read(contentsOf: url)
            original = image
            processed = nil
            history = [HistoryEntry(planes: nil, label: "Original")]
            historyIndex = 0
            fileName = url.lastPathComponent
            let channels = image.channelCount > 1 ? ", \(image.channelCount) channels" : ""
            statusMessage = "Loaded \(image.width)×\(image.height)\(channels), BITPIX \(image.header.bitpix)"
        } catch {
            statusMessage = "Open failed: \(error)"
        }
    }

    // MARK: Processing

    func refreshTelemetry() {
        guard useLiveTelemetry else { return }
        statusMessage = "Reading telemetry…"
        let manager = TelemetryManager(
            location: CoreLocationProvider(),
            pointing: pointingProvider(),
            weather: liveWeatherProvider(),
            baseline: telemetry
        )
        Task {
            let snapshot = await manager.snapshot()
            self.telemetry = snapshot
            self.statusMessage = String(
                format: "Telemetry: %.2f°N %.2f°E, RH %.0f%%, AOD %.3f",
                snapshot.latitude, snapshot.longitude,
                snapshot.relativeHumidity * 100, snapshot.aerosolOpticalDepth
            )
        }
    }

    private func pointingProvider() -> PointingProviding? {
        #if os(iOS)
        return CoreMotionPointingProvider()
        #else
        return nil
        #endif
    }

    private func liveWeatherProvider() -> WeatherProviding {
        if #available(macOS 13.0, iOS 16.0, *) {
            return WeatherService()
        }
        return StaticWeatherProvider()
    }

    func process() {
        guard let image = original, !isProcessing else { return }
        isProcessing = true
        statusMessage = "Processing…"
        let pipeline = GradientRemovalPipeline(
            telemetry: telemetry,
            degree: degree,
            physicsStrength: physicsStrength
        )
        let engine = subtractEngine
        Task.detached(priority: .userInitiated) {
            do {
                // Each channel gets its own scattering wavelength, prior
                // gain, and surface fit (skyglow is color-dependent). The
                // full per-pixel pipeline runs on GPU where Metal is
                // available; the CPU pipeline is the reference fallback.
                let fitter = PolynomialFitter(degree: pipeline.degree,
                                              sampleSpacing: pipeline.sampleSpacing)
                let fovY = pipeline.telemetry.fieldOfViewDegrees
                    * Double(image.height) / Double(image.width)
                var usedGPU = true
                var final: [[Float]] = []
                for (index, plane) in image.planes.enumerated() {
                    let wavelength = pipeline.wavelength(
                        forChannel: index, of: image.channelCount
                    )
                    let tau = RayleighMie.totalOpticalDepth(
                        wavelengthMicrons: wavelength,
                        beta: pipeline.telemetry.aerosolOpticalDepth,
                        relativeHumidity: pipeline.telemetry.relativeHumidity
                    )
                    if let gpu = engine.processPlane(
                        pixels: plane, width: image.width, height: image.height,
                        opticalDepth: tau,
                        altitudeCenterDegrees: pipeline.telemetry.targetAltitudeDegrees,
                        fovYDegrees: fovY,
                        physicsStrength: pipeline.physicsStrength,
                        fitter: fitter
                    ) {
                        final.append(gpu)
                    } else {
                        usedGPU = false
                        var channelPipeline = pipeline
                        channelPipeline.telemetry.wavelengthMicrons = wavelength
                        let result = try channelPipeline.process(
                            pixels: plane, width: image.width, height: image.height
                        )
                        final.append(result.pixels)
                    }
                }
                let path = usedGPU ? "GPU" : "CPU"
                let label = "Physics + degree-\(pipeline.degree.rawValue) fit (\(path))"
                let planes = final
                await MainActor.run {
                    self.recordRun(planes, label: label)
                    self.isProcessing = false
                    self.statusMessage = "Done — \(label.lowercased())"
                }
            } catch {
                await MainActor.run {
                    self.isProcessing = false
                    self.statusMessage = "Processing failed: \(error)"
                }
            }
        }
    }
}
