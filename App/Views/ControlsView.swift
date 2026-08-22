import SwiftUI
import FitsnFinishCore

/// Right-hand control panel: telemetry inputs, engine tuning, and actions.
struct ControlsView: View {
    @EnvironmentObject private var model: DocumentModel

    var body: some View {
        Form {
            Section("Telemetry") {
                Toggle("Use live telemetry", isOn: $model.useLiveTelemetry)
                    .onChange(of: model.useLiveTelemetry) { _, enabled in
                        if enabled { model.refreshTelemetry() }
                    }
                LabeledContent("Latitude") {
                    TextField("deg", value: $model.telemetry.latitude, format: .number)
                }
                LabeledContent("Longitude") {
                    TextField("deg", value: $model.telemetry.longitude, format: .number)
                }
                LabeledContent("Target altitude") {
                    TextField("deg", value: $model.telemetry.targetAltitudeDegrees, format: .number)
                }
                LabeledContent("Target azimuth") {
                    TextField("deg", value: $model.telemetry.targetAzimuthDegrees, format: .number)
                }
                LabeledContent("Field of view") {
                    TextField("deg", value: $model.telemetry.fieldOfViewDegrees, format: .number)
                }
                LabeledContent("Humidity") {
                    Slider(value: $model.telemetry.relativeHumidity, in: 0 ... 1)
                    Text(model.telemetry.relativeHumidity, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                LabeledContent("Aerosol depth (β)") {
                    TextField("AOD", value: $model.telemetry.aerosolOpticalDepth, format: .number)
                }
            }

            Section("Hybrid Engine") {
                LabeledContent("Physics strength") {
                    Slider(value: $model.physicsStrength, in: 0 ... 2)
                    Text(String(format: "%.2f", model.physicsStrength))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                Picker("Surface degree", selection: $model.degree) {
                    Text("1st (planar)").tag(PolynomialFitter.Degree.linear)
                    Text("2nd (quadratic)").tag(PolynomialFitter.Degree.quadratic)
                }
                .pickerStyle(.segmented)
            }

            Section("Preview") {
                LabeledContent("Stretch midtone") {
                    Slider(value: $model.previewMidtone, in: 0.01 ... 0.5)
                }
                Toggle("Show original", isOn: $model.showOriginal)
                    .disabled(model.processed == nil)
            }

            Section {
                Button {
                    model.process()
                } label: {
                    if model.isProcessing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Remove Gradients", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.original == nil || model.isProcessing)

                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
    }
}
