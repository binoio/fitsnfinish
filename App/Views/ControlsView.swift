import SwiftUI
import FitsnFinishCore

/// An interactive radial angle dial (0°–360° or custom range) that can be
/// dragged to adjust an angle visually alongside a numeric text field.
struct AngleDial: View {
    @Binding var angleDegrees: Double
    var range: ClosedRange<Double> = 0 ... 360
    var step: Double = 1.0

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let rad = (angleDegrees - 90) * .pi / 180
            let needleRadius = max(radius - 2.5, 2)
            let pointerEnd = CGPoint(
                x: center.x + needleRadius * CGFloat(cos(rad)),
                y: center.y + needleRadius * CGFloat(sin(rad))
            )

            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1.5)
                    .background(Circle().fill(Color.secondary.opacity(0.08)))

                // Top (0° / North) reference pip
                Circle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 2.5, height: 2.5)
                    .offset(y: -(radius - 2.5))

                // Pointer needle
                Path { path in
                    path.move(to: center)
                    path.addLine(to: pointerEnd)
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))

                // Center pivot
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 3.5, height: 3.5)
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let dx = value.location.x - center.x
                        let dy = value.location.y - center.y
                        var degrees = atan2(dy, dx) * 180 / .pi + 90
                        if degrees < 0 { degrees += 360 }
                        if range.lowerBound < 0 {
                            if degrees > 180 { degrees -= 360 }
                        }
                        let clamped = min(max(degrees, range.lowerBound), range.upperBound)
                        angleDegrees = (clamped / step).rounded() * step
                    }
            )
        }
        .frame(width: 22, height: 22)
        .help("Drag to adjust angle")
    }
}

/// Right-hand control panel: telemetry inputs, engine tuning, preview stretch, and actions.
struct ControlsView: View {
    @EnvironmentObject private var model: DocumentModel
    @EnvironmentObject private var presets: PresetStore

    @AppStorage("controls.sitePointingExpanded") private var isSitePointingExpanded = true
    @AppStorage("controls.environmentExpanded") private var isEnvironmentExpanded = false
    @AppStorage("controls.engineExpanded") private var isEngineExpanded = false
    @AppStorage("controls.previewExpanded") private var isPreviewExpanded = true

    var body: some View {
        Form {
            if !presets.presets.isEmpty {
                Section {
                    Menu {
                        ForEach(presets.presets) { preset in
                            Button(preset.name) { presets.apply(preset, to: model) }
                        }
                    } label: {
                        Label("Apply Preset", systemImage: "slider.horizontal.3")
                    }
                }
            }

            // 1. Site & Telescope Pointing
            Section {
                DisclosureGroup(isExpanded: $isSitePointingExpanded) {
                    Toggle("Use live telemetry", isOn: $model.useLiveTelemetry)
                        .onChange(of: model.useLiveTelemetry) { _, enabled in
                            if enabled { model.refreshTelemetry() }
                        }
                    LabeledContent("Latitude") {
                        HStack(spacing: 4) {
                            TextField("°", value: $model.telemetry.latitude, format: .number.precision(.fractionLength(4)))
                                .frame(width: 80)
                            Text("°").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Longitude") {
                        HStack(spacing: 4) {
                            TextField("°", value: $model.telemetry.longitude, format: .number.precision(.fractionLength(4)))
                                .frame(width: 80)
                            Text("°").foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    Toggle("Pointing from image header", isOn: $model.usesHeaderAstrometry)
                    LabeledContent("Target altitude") {
                        HStack(spacing: 6) {
                            AngleDial(angleDegrees: $model.telemetry.targetAltitudeDegrees, range: 0 ... 90)
                            TextField("°", value: $model.telemetry.targetAltitudeDegrees, format: .number.precision(.fractionLength(1)))
                                .frame(width: 60)
                            Text("°").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Target azimuth") {
                        HStack(spacing: 6) {
                            AngleDial(angleDegrees: $model.telemetry.targetAzimuthDegrees, range: 0 ... 360)
                            TextField("°", value: $model.telemetry.targetAzimuthDegrees, format: .number.precision(.fractionLength(1)))
                                .frame(width: 60)
                            Text("°").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Field of view") {
                        HStack(spacing: 4) {
                            TextField("°", value: $model.telemetry.fieldOfViewDegrees, format: .number.precision(.fractionLength(2)))
                                .frame(width: 80)
                            Text("°").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Field rotation") {
                        HStack(spacing: 6) {
                            AngleDial(angleDegrees: $model.telemetry.fieldRotationDegrees, range: -180 ... 180)
                            TextField("°", value: $model.telemetry.fieldRotationDegrees, format: .number.precision(.fractionLength(1)))
                                .frame(width: 60)
                            Text("°").foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    Label("Site & Pointing", systemImage: "location.north.circle")
                        .font(.headline)
                }
            }

            // 2. Atmosphere & Sky Glow
            Section {
                DisclosureGroup(isExpanded: $isEnvironmentExpanded) {
                    LabeledContent("Humidity") {
                        Slider(value: $model.telemetry.relativeHumidity, in: 0 ... 1)
                        Text(model.telemetry.relativeHumidity, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    LabeledContent("Aerosol depth (β)") {
                        TextField("AOD", value: $model.telemetry.aerosolOpticalDepth, format: .number)
                    }
                    LabeledContent("Ångström α") {
                        TextField("α", value: $model.telemetry.angstromExponent, format: .number)
                    }
                    Divider()
                    Toggle("Moonlight model", isOn: $model.telemetry.moonlightEnabled)
                    LabeledContent("Light dome azimuth") {
                        HStack(spacing: 6) {
                            AngleDial(angleDegrees: $model.telemetry.lightDomeAzimuthDegrees, range: 0 ... 360)
                            TextField("°", value: $model.telemetry.lightDomeAzimuthDegrees, format: .number.precision(.fractionLength(1)))
                                .frame(width: 60)
                            Text("°").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Light dome strength") {
                        Slider(value: $model.telemetry.lightDomeIntensity, in: 0 ... 1)
                        Text(String(format: "%.2f", model.telemetry.lightDomeIntensity))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                } label: {
                    Label("Atmosphere & Sky Glow", systemImage: "cloud.sun")
                        .font(.headline)
                }
            }

            // 3. Gradient Removal Engine
            Section {
                DisclosureGroup(isExpanded: $isEngineExpanded) {
                    LabeledContent("Physics strength") {
                        Slider(value: $model.physicsStrength, in: 0 ... 2)
                        Text(String(format: "%.2f", model.physicsStrength))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    Picker("Surface degree", selection: $model.degree) {
                        Text("1st (Planar)").tag(PolynomialFitter.Degree.linear)
                        Text("2nd (Quadratic)").tag(PolynomialFitter.Degree.quadratic)
                    }
                    .pickerStyle(.menu)
                } label: {
                    Label("Gradient Engine", systemImage: "slider.horizontal.2.square")
                        .font(.headline)
                }
            }

            // 4. Display Preview
            Section {
                DisclosureGroup(isExpanded: $isPreviewExpanded) {
                    LabeledContent("Stretch midtone") {
                        Slider(value: $model.previewMidtone, in: 0.01 ... 0.5)
                    }
                    Picker("View", selection: $model.viewMode) {
                        ForEach(DocumentModel.ViewMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(model.processed == nil)
                } label: {
                    Label("Display Preview", systemImage: "eye")
                        .font(.headline)
                }
            }

            // 5. Actions & Execution
            Section {
                Button {
                    model.process()
                } label: {
                    if model.isProcessing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(
                            model.processed == nil ? "Remove Gradients" : "Recompute Gradients",
                            systemImage: model.processed == nil ? "wand.and.stars" : "arrow.clockwise"
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.original == nil || model.isProcessing)

                if !model.statusMessage.isEmpty {
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                #if !os(macOS)
                if let shareItem = model.shareItem {
                    ShareLink(
                        item: shareItem,
                        preview: SharePreview(shareItem.name, image: Image(systemName: "moon.stars"))
                    ) {
                        Label("Share Processed FITS", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    model.isPresetLibraryPresented = true
                } label: {
                    Label("Preset Library", systemImage: "books.vertical")
                }
                #endif
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
    }
}
