import Foundation
import SwiftUI
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
}

/// UserDefaults-backed preset storage.
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
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    func saveCurrent(from model: DocumentModel, name: String) {
        let preset = ProcessingPreset(
            name: name,
            latitude: model.telemetry.latitude,
            longitude: model.telemetry.longitude,
            targetAltitudeDegrees: model.telemetry.targetAltitudeDegrees,
            targetAzimuthDegrees: model.telemetry.targetAzimuthDegrees,
            relativeHumidity: model.telemetry.relativeHumidity,
            aerosolOpticalDepth: model.telemetry.aerosolOpticalDepth,
            fieldOfViewDegrees: model.telemetry.fieldOfViewDegrees,
            degree: model.degree.rawValue,
            physicsStrength: model.physicsStrength
        )
        // Same name replaces the existing preset.
        presets.removeAll { $0.name == name }
        presets.append(preset)
        presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist()
    }

    func apply(_ preset: ProcessingPreset, to model: DocumentModel) {
        model.telemetry.latitude = preset.latitude
        model.telemetry.longitude = preset.longitude
        model.telemetry.targetAltitudeDegrees = preset.targetAltitudeDegrees
        model.telemetry.targetAzimuthDegrees = preset.targetAzimuthDegrees
        model.telemetry.relativeHumidity = preset.relativeHumidity
        model.telemetry.aerosolOpticalDepth = preset.aerosolOpticalDepth
        model.telemetry.fieldOfViewDegrees = preset.fieldOfViewDegrees
        model.degree = PolynomialFitter.Degree(rawValue: preset.degree) ?? .linear
        model.physicsStrength = preset.physicsStrength
        model.statusMessage = "Applied preset “\(preset.name)”"
    }

    func delete(_ preset: ProcessingPreset) {
        presets.removeAll { $0.id == preset.id }
        persist()
    }
}

/// Preset management and app information — the macOS Settings window and
/// the iOS settings sheet share this view.
struct SettingsView: View {
    @EnvironmentObject private var model: DocumentModel
    @EnvironmentObject private var store: PresetStore
    @State private var newPresetName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Presets (rig + site)") {
                if store.presets.isEmpty {
                    Text("No presets yet. Set up telemetry and engine values in the main window, then save them here under a name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.presets) { preset in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(preset.name)
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

            Section("About") {
                LabeledContent("Version") {
                    Text(Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString"
                    ) as? String ?? "dev")
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
        #if os(macOS)
        .frame(width: 500, height: 400)
        #endif
    }
}
