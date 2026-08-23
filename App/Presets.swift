import Foundation
import SwiftUI
import UniformTypeIdentifiers
import FitsnFinishCore

/// A named rig + site combination: everything the engine needs that isn't
/// derived from the image itself.
struct ProcessingPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var targetAltitudeDegrees: Double
    var targetAzimuthDegrees: Double
    var relativeHumidity: Double
    var aerosolOpticalDepth: Double
    var fieldOfViewDegrees: Double
    var degree: Int
    var physicsStrength: Float
    // 0.4.0 physics fields — decoded with defaults so pre-0.4.0 preset
    // files keep importing.
    var fieldRotationDegrees: Double = 0
    var moonlightEnabled: Bool = true
    var lightDomeAzimuthDegrees: Double = 0
    var lightDomeIntensity: Double = 0

    init(
        id: UUID = UUID(), name: String,
        latitude: Double, longitude: Double,
        targetAltitudeDegrees: Double, targetAzimuthDegrees: Double,
        relativeHumidity: Double, aerosolOpticalDepth: Double,
        fieldOfViewDegrees: Double, degree: Int, physicsStrength: Float,
        fieldRotationDegrees: Double = 0, moonlightEnabled: Bool = true,
        lightDomeAzimuthDegrees: Double = 0, lightDomeIntensity: Double = 0
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.targetAltitudeDegrees = targetAltitudeDegrees
        self.targetAzimuthDegrees = targetAzimuthDegrees
        self.relativeHumidity = relativeHumidity
        self.aerosolOpticalDepth = aerosolOpticalDepth
        self.fieldOfViewDegrees = fieldOfViewDegrees
        self.degree = degree
        self.physicsStrength = physicsStrength
        self.fieldRotationDegrees = fieldRotationDegrees
        self.moonlightEnabled = moonlightEnabled
        self.lightDomeAzimuthDegrees = lightDomeAzimuthDegrees
        self.lightDomeIntensity = lightDomeIntensity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        targetAltitudeDegrees = try container.decode(Double.self, forKey: .targetAltitudeDegrees)
        targetAzimuthDegrees = try container.decode(Double.self, forKey: .targetAzimuthDegrees)
        relativeHumidity = try container.decode(Double.self, forKey: .relativeHumidity)
        aerosolOpticalDepth = try container.decode(Double.self, forKey: .aerosolOpticalDepth)
        fieldOfViewDegrees = try container.decode(Double.self, forKey: .fieldOfViewDegrees)
        degree = try container.decode(Int.self, forKey: .degree)
        physicsStrength = try container.decode(Float.self, forKey: .physicsStrength)
        fieldRotationDegrees = try container.decodeIfPresent(Double.self, forKey: .fieldRotationDegrees) ?? 0
        moonlightEnabled = try container.decodeIfPresent(Bool.self, forKey: .moonlightEnabled) ?? true
        lightDomeAzimuthDegrees = try container.decodeIfPresent(Double.self, forKey: .lightDomeAzimuthDegrees) ?? 0
        lightDomeIntensity = try container.decodeIfPresent(Double.self, forKey: .lightDomeIntensity) ?? 0
    }
}

/// UserDefaults-backed preset storage with JSON import/export.
@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var presets: [ProcessingPreset] = []
    private static let defaultsKey = "FFProcessingPresets"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([ProcessingPreset].self, from: data) {
            presets = decoded
        }
    }

    private func persist() {
        presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    func makePreset(from model: DocumentModel, name: String) -> ProcessingPreset {
        ProcessingPreset(
            name: name,
            latitude: model.telemetry.latitude,
            longitude: model.telemetry.longitude,
            targetAltitudeDegrees: model.telemetry.targetAltitudeDegrees,
            targetAzimuthDegrees: model.telemetry.targetAzimuthDegrees,
            relativeHumidity: model.telemetry.relativeHumidity,
            aerosolOpticalDepth: model.telemetry.aerosolOpticalDepth,
            fieldOfViewDegrees: model.telemetry.fieldOfViewDegrees,
            degree: model.degree.rawValue,
            physicsStrength: model.physicsStrength,
            fieldRotationDegrees: model.telemetry.fieldRotationDegrees,
            moonlightEnabled: model.telemetry.moonlightEnabled,
            lightDomeAzimuthDegrees: model.telemetry.lightDomeAzimuthDegrees,
            lightDomeIntensity: model.telemetry.lightDomeIntensity
        )
    }

    func saveCurrent(from model: DocumentModel, name: String) {
        let preset = makePreset(from: model, name: name)
        // Same name replaces the existing preset.
        presets.removeAll { $0.name == name }
        presets.append(preset)
        persist()
    }

    /// Single-preset JSON of the current settings, for File ▸ Export as
    /// Preset (same schema as the library's export, so files interchange).
    func exportCurrentData(from model: DocumentModel, name: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode([makePreset(from: model, name: name)])
    }

    func apply(_ preset: ProcessingPreset, to model: DocumentModel) {
        model.telemetry.latitude = preset.latitude
        model.telemetry.longitude = preset.longitude
        model.telemetry.targetAltitudeDegrees = preset.targetAltitudeDegrees
        model.telemetry.targetAzimuthDegrees = preset.targetAzimuthDegrees
        model.telemetry.relativeHumidity = preset.relativeHumidity
        model.telemetry.aerosolOpticalDepth = preset.aerosolOpticalDepth
        model.telemetry.fieldOfViewDegrees = preset.fieldOfViewDegrees
        model.telemetry.fieldRotationDegrees = preset.fieldRotationDegrees
        model.telemetry.moonlightEnabled = preset.moonlightEnabled
        model.telemetry.lightDomeAzimuthDegrees = preset.lightDomeAzimuthDegrees
        model.telemetry.lightDomeIntensity = preset.lightDomeIntensity
        model.degree = PolynomialFitter.Degree(rawValue: preset.degree) ?? .linear
        model.physicsStrength = preset.physicsStrength
        model.statusMessage = "Applied preset “\(preset.name)”"
    }

    /// Imports a preset file and applies its first preset to the session —
    /// the File ▸ Import Preset path, no library window needed.
    func importAndApply(data: Data, to model: DocumentModel) throws {
        let count = try importData(data)
        if count > 0, let first = try JSONDecoder()
            .decode([ProcessingPreset].self, from: data).first,
           let stored = presets.first(where: { $0.name == first.name }) {
            apply(stored, to: model)
        }
    }

    func rename(_ preset: ProcessingPreset, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let index = presets.firstIndex(where: { $0.id == preset.id })
        else { return }
        presets[index].name = trimmed
        persist()
    }

    func delete(_ preset: ProcessingPreset) {
        presets.removeAll { $0.id == preset.id }
        persist()
    }

    // MARK: File exchange

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(presets)
    }

    /// Merges presets from a JSON file; imported presets replace existing
    /// ones with the same name. Returns the number imported.
    func importData(_ data: Data) throws -> Int {
        let imported = try JSONDecoder().decode([ProcessingPreset].self, from: data)
        for preset in imported {
            presets.removeAll { $0.name == preset.name }
            presets.append(preset)
        }
        persist()
        return imported.count
    }
}

/// JSON file wrapper for preset import/export.
struct PresetsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

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

/// One library row: inline-renamable name, summary, apply/delete.
private struct PresetRow: View {
    @EnvironmentObject private var model: DocumentModel
    @EnvironmentObject private var store: PresetStore
    let preset: ProcessingPreset
    @State private var draftName: String

    init(preset: ProcessingPreset) {
        self.preset = preset
        _draftName = State(initialValue: preset.name)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .onSubmit { store.rename(preset, to: draftName) }
                Text(String(
                    format: "alt %.0f°, FOV %.2f°, RH %.0f%%, β %.3f, degree %d",
                    preset.targetAltitudeDegrees,
                    preset.fieldOfViewDegrees,
                    preset.relativeHumidity * 100,
                    preset.aerosolOpticalDepth,
                    preset.degree
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Apply") { store.apply(preset, to: model) }
                .buttonStyle(.borderless)
            Button(role: .destructive) {
                store.delete(preset)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }
}

/// The Preset Library: load, save, rename, delete, and exchange presets as
/// JSON files. Shown as its own window on macOS and a sheet on iOS.
struct PresetLibraryView: View {
    @EnvironmentObject private var model: DocumentModel
    @EnvironmentObject private var store: PresetStore
    @Environment(\.dismiss) private var dismiss
    @State private var newPresetName = ""
    @State private var isImporterPresented = false
    @State private var isExporterPresented = false
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section("Presets (rig + site)") {
                if store.presets.isEmpty {
                    Text("No presets yet. Set up telemetry and engine values in the main window, then save them here under a name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.presets) { preset in
                    PresetRow(preset: preset)
                        .id(preset.id)
                }
                HStack {
                    TextField("New preset name", text: $newPresetName)
                        .textFieldStyle(.roundedBorder)
                    Button("Save Current") {
                        store.saveCurrent(from: model, name: newPresetName)
                        newPresetName = ""
                    }
                    .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section {
                HStack {
                    Button {
                        isImporterPresented = true
                    } label: {
                        Label("Import…", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        isExporterPresented = true
                    } label: {
                        Label("Export…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.presets.isEmpty)
                    Spacer()
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            #if !os(macOS)
            Section {
                Button("Done") { dismiss() }
                    .frame(maxWidth: .infinity)
            }
            #endif
        }
        .formStyle(.grouped)
        .navigationTitle("Preset Library")
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.json]
        ) { result in
            switch result {
            case .success(let url):
                importPresets(from: url)
            case .failure(let error):
                statusMessage = "Import failed: \(error.localizedDescription)"
            }
        }
        .fileExporter(
            isPresented: $isExporterPresented,
            document: try? PresetsDocument(data: store.exportData()),
            contentType: .json,
            defaultFilename: "FitsnFinish-Presets"
        ) { result in
            switch result {
            case .success(let url):
                statusMessage = "Exported \(store.presets.count) preset(s) to \(url.lastPathComponent)"
            case .failure(let error):
                statusMessage = "Export failed: \(error.localizedDescription)"
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
    }

    private func importPresets(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let count = try store.importData(Data(contentsOf: url))
            statusMessage = "Imported \(count) preset(s)"
        } catch {
            statusMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}

/// Settings proper: app information only — presets live in the Preset
/// Library window.
struct SettingsView: View {
    var body: some View {
        Form {
            Section("About") {
                LabeledContent("Version") {
                    Text(Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString"
                    ) as? String ?? "dev")
                }
                Link("Source & documentation",
                     destination: URL(string: "https://github.com/mabino/fitsnfinish")!)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 400, height: 180)
        #endif
    }
}
