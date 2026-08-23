import SwiftUI
import UniformTypeIdentifiers
import FitsnFinishCore

extension UTType {
    static var fits: UTType {
        UTType(filenameExtension: "fits") ?? .data
    }

    static var xisf: UTType {
        UTType(filenameExtension: "xisf") ?? .data
    }
}

@main
struct FitsnFinishApp: App {
    @StateObject private var model = DocumentModel()
    @StateObject private var presets = PresetStore()
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif
    #if os(macOS) && canImport(Sparkle)
    @StateObject private var updater = UpdaterModel()
    #endif

    var body: some Scene {
        WindowGroup("FITS n' Finish", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(presets)
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
                #if os(macOS)
                Button("New Window") { openWindow(id: "main") }
                    .keyboardShortcut("n")
                Divider()
                #endif
                Button("Open FITS…") { model.isImporterPresented = true }
                    .keyboardShortcut("o")
                Button("Export Processed FITS…") { model.isExporterPresented = true }
                    .keyboardShortcut("e")
                    .disabled(model.processed == nil)
                Divider()
                Button("Import Preset…") { model.isPresetImporterPresented = true }
                Button("Export Settings as Preset…") { model.isPresetExporterPresented = true }
            }
        }

        #if os(macOS)
        Window("Preset Library", id: "preset-library") {
            PresetLibraryView()
                .environmentObject(model)
                .environmentObject(presets)
        }

        Settings {
            SettingsView()
        }
        #endif
    }
}

#if !os(macOS)
/// Share-sheet payload: writes the processed frame as FITS on demand when
/// the user picks a destination (AirDrop, Files, a stacking app…).
struct ExportableFITS: Transferable {
    let planes: [[Float]]
    let width: Int
    let height: Int
    let header: FITSHeader?
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .fits) { item in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(item.name)
                .appendingPathExtension("fits")
            let data = FITSWriter.data(
                planes: item.planes, width: item.width, height: item.height,
                preservingFrom: item.header
            )
            try data.write(to: url)
            return SentTransferredFile(url)
        }
    }
}
#endif

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
    @EnvironmentObject private var presets: PresetStore
    @Environment(\.undoManager) private var undoManager

    private func importPreset(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        do {
            try presets.importAndApply(data: Data(contentsOf: url), to: model)
        } catch {
            model.statusMessage = "Preset import failed: \(error.localizedDescription)"
        }
    }
    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        layout
            .navigationTitle(model.fileName ?? "FITS n' Finish")
            #if !os(macOS)
            .sheet(isPresented: $model.isPresetLibraryPresented) {
                PresetLibraryView()
            }
            #endif
            .fileImporter(
                isPresented: $model.isPresetImporterPresented,
                allowedContentTypes: [.json]
            ) { result in
                if case .success(let url) = result {
                    importPreset(from: url)
                }
            }
            .fileExporter(
                isPresented: $model.isPresetExporterPresented,
                document: try? PresetsDocument(
                    data: presets.exportCurrentData(
                        from: model,
                        name: (model.fileName as NSString?)?.deletingPathExtension ?? "Preset"
                    )
                ),
                contentType: .json,
                defaultFilename: (model.fileName as NSString?)?.deletingPathExtension ?? "Preset"
            ) { result in
                switch result {
                case .success(let url):
                    model.statusMessage = "Exported preset \(url.lastPathComponent)"
                case .failure(let error):
                    model.statusMessage = "Preset export failed: \(error.localizedDescription)"
                }
            }
            .onAppear { model.undoManager = undoManager }
            .fileImporter(
                isPresented: $model.isImporterPresented,
                allowedContentTypes: [.fits, .xisf, .data]
            ) { result in
                if case .success(let url) = result {
                    model.open(url: url)
                }
            }
            // Files-app / drag-in entry point (tap a FITS or XISF in Files,
            // or hand one over from a smart-telescope app).
            .onOpenURL { url in
                model.open(url: url)
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
    enum ViewMode: String, CaseIterable, Identifiable {
        case result = "Result"
        case original = "Original"
        case physicalModel = "Physical"
        case surface = "Surface"
        var id: String { rawValue }
    }
    @Published var viewMode: ViewMode = .result
    @Published var isProcessing = false
    @Published var statusMessage = "Ready"
    @Published var isImporterPresented = false
    @Published var isExporterPresented = false
    @Published var isPresetLibraryPresented = false
    @Published var isPresetImporterPresented = false
    @Published var isPresetExporterPresented = false
    /// Populate pointing/timing from the image header on open.
    @Published var usesHeaderAstrometry = true

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
    /// The host window's undo manager: registering here puts processing
    /// steps on the standard Edit-menu Undo/Redo (⌘Z/⇧⌘Z) and, on iOS, the
    /// system three-finger and shake gestures.
    weak var undoManager: UndoManager?

    @Published var telemetry = TelemetrySnapshot()
    @Published var degree: PolynomialFitter.Degree = .linear
    @Published var physicsStrength: Float = 1.0
    @Published var previewMidtone: Float = 0.15
    @Published var useLiveTelemetry = false

    private let subtractEngine = MetalSubtractEngine()

    var imageSize: (width: Int, height: Int)? {
        original.map { ($0.width, $0.height) }
    }

    /// The actual subtracted surfaces from the most recent run, per channel
    /// — stage 1 (physical model) and stage 2 (polynomial), independently
    /// inspectable.
    @Published private(set) var lastPriors: [[Float]]?
    @Published private(set) var lastSurfaces: [[Float]]?

    var displayPlanes: [[Float]]? {
        switch viewMode {
        case .result: return processed ?? original?.planes
        case .original: return original?.planes
        case .physicalModel: return lastPriors.map(Self.normalizedForDisplay)
        case .surface: return lastSurfaces.map(Self.normalizedForDisplay)
        }
    }

    /// Diagnostic surfaces live in model units, not image units; min–max
    /// normalize each plane so their shape is visible under the preview
    /// stretch.
    private static func normalizedForDisplay(_ planes: [[Float]]) -> [[Float]] {
        planes.map { plane in
            let lo = plane.min() ?? 0
            let hi = plane.max() ?? 1
            let span = max(hi - lo, 1e-9)
            return plane.map { ($0 - lo) / span }
        }
    }

    var exportDocument: FITSDocument? {
        guard let processed, let size = imageSize else { return nil }
        return FITSDocument(
            data: FITSWriter.data(
                planes: processed, width: size.width, height: size.height,
                preservingFrom: original?.header
            )
        )
    }

    var canUndo: Bool { historyIndex > 0 }
    var canRedo: Bool { historyIndex < history.count - 1 }

    func undo() {
        guard canUndo else { return }
        historyIndex -= 1
        processed = history[historyIndex].planes
        statusMessage = "Undid to: \(history[historyIndex].label)"
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.redo() }
        }
        undoManager?.setActionName("Gradient Removal")
    }

    func redo() {
        guard canRedo else { return }
        historyIndex += 1
        processed = history[historyIndex].planes
        statusMessage = "Redid to: \(history[historyIndex].label)"
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.undo() }
        }
        undoManager?.setActionName("Gradient Removal")
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
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.undo() }
        }
        undoManager?.setActionName("Gradient Removal")
    }

    #if !os(macOS)
    var shareItem: ExportableFITS? {
        guard let processed, let size = imageSize else { return nil }
        return ExportableFITS(
            planes: processed, width: size.width, height: size.height,
            header: original?.header, name: exportFileName
        )
    }
    #endif

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
            lastPriors = nil
            lastSurfaces = nil
            viewMode = .result
            fileName = url.lastPathComponent
            let channels = image.channelCount > 1 ? ", \(image.channelCount) channels" : ""
            var note = ""
            if usesHeaderAstrometry, applyHeaderAstrometry(from: image) {
                note = " — pointing from header"
            }
            statusMessage = "Loaded \(image.width)×\(image.height)\(channels), BITPIX \(image.header.bitpix)\(note)"
        } catch {
            statusMessage = "Open failed: \(error)"
        }
    }

    /// Fills telemetry from whatever pointing/timing the file carries.
    /// Returns true when something was applied.
    private func applyHeaderAstrometry(from image: FITSImage) -> Bool {
        let astrometry = HeaderAstrometry(header: image.header)
        var applied = false
        if let scale = astrometry.pixelScaleDegrees {
            telemetry.fieldOfViewDegrees = scale * Double(image.width)
            applied = true
        }
        if let date = astrometry.observationDate {
            telemetry.observationDate = date
            telemetry.exposureSeconds = astrometry.exposureSeconds ?? 0
            applied = true
        }
        if let ra = astrometry.rightAscensionDegrees,
           let dec = astrometry.declinationDegrees {
            telemetry.rightAscensionDegrees = ra
            telemetry.declinationDegrees = dec
            applied = true
            if let date = telemetry.observationDate {
                let position = Astrometry.horizontal(
                    rightAscensionDegrees: ra, declinationDegrees: dec,
                    latitude: telemetry.latitude, longitude: telemetry.longitude,
                    date: date
                )
                telemetry.targetAltitudeDegrees = position.altitudeDegrees
                telemetry.targetAzimuthDegrees = position.azimuthDegrees
                if let north = astrometry.northAngleDegrees {
                    let parallactic = Astrometry.parallacticAngle(
                        rightAscensionDegrees: ra, declinationDegrees: dec,
                        latitude: telemetry.latitude, longitude: telemetry.longitude,
                        date: date
                    )
                    telemetry.fieldRotationDegrees = north + parallactic
                }
            }
        }
        return applied
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
                var usedGPU = true
                var final: [[Float]] = []
                var priors: [[Float]] = []
                var surfaces: [[Float]] = []
                for (index, plane) in image.planes.enumerated() {
                    let wavelength = pipeline.wavelength(
                        forChannel: index, of: image.channelCount
                    )
                    var channelTelemetry = pipeline.telemetry
                    channelTelemetry.wavelengthMicrons = wavelength
                    let renderModel = AtmosphericModel(telemetry: channelTelemetry)
                        .renderModel(width: image.width, height: image.height)
                    if let gpu = engine.processPlane(
                        pixels: plane, width: image.width, height: image.height,
                        renderModel: renderModel,
                        physicsStrength: pipeline.physicsStrength,
                        fitter: fitter
                    ) {
                        final.append(gpu.final)
                        priors.append(gpu.prior)
                        surfaces.append(gpu.surface)
                    } else {
                        usedGPU = false
                        var channelPipeline = pipeline
                        channelPipeline.telemetry.wavelengthMicrons = wavelength
                        let result = try channelPipeline.process(
                            pixels: plane, width: image.width, height: image.height
                        )
                        final.append(result.pixels)
                        priors.append(result.physicalPrior)
                        surfaces.append(result.polynomialSurface)
                    }
                }
                let path = usedGPU ? "GPU" : "CPU"
                let label = "Physics + degree-\(pipeline.degree.rawValue) fit (\(path))"
                let planes = final
                let diagnosticPriors = priors
                let diagnosticSurfaces = surfaces
                await MainActor.run {
                    self.lastPriors = diagnosticPriors
                    self.lastSurfaces = diagnosticSurfaces
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
