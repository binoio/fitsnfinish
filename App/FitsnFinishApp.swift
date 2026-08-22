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

    var body: some Scene {
        WindowGroup("FITS n' Finish") {
            ContentView()
                .environmentObject(model)
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 600)
                #endif
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open FITS…") { model.isImporterPresented = true }
                    .keyboardShortcut("o")
                Button("Export Processed FITS…") { model.isExporterPresented = true }
                    .keyboardShortcut("e")
                    .disabled(model.processed == nil)
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
                // Each color channel gets its own prior gain and surface fit
                // (skyglow is color-dependent). Prefer the GPU blend when
                // Metal is available; the CPU result is the reference
                // fallback.
                let results = try pipeline.processPlanes(image: image)
                let final = zip(image.planes, results).map { plane, result in
                    engine.subtract(
                        image: plane,
                        prior: result.physicalPrior,
                        surface: result.polynomialSurface,
                        width: image.width,
                        height: image.height,
                        physicsStrength: pipeline.physicsStrength
                    ) ?? result.pixels
                }
                await MainActor.run {
                    self.processed = final
                    self.isProcessing = false
                    self.statusMessage = "Done — hybrid physics + degree-\(self.degree.rawValue) fit"
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
