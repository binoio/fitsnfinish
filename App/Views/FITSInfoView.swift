import SwiftUI
import FitsnFinishCore

/// Modal inspector window/sheet displaying resolution, astrometric pointing,
/// optical scale, and raw header cards of the loaded FITS or XISF file.
struct FITSInfoView: View {
    @EnvironmentObject private var model: DocumentModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab = 0
    @State private var searchKeyword = ""
    @State private var copiedNotice = false

    private var image: FITSImage? { model.original }
    private var header: FITSHeader? { image?.header }
    private var astrometry: HeaderAstrometry? { header.map(HeaderAstrometry.init) }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("FITS Information")
                        .font(.headline)
                    if let name = model.fileName {
                        Text(name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    copySummaryToClipboard()
                } label: {
                    Label(copiedNotice ? "Copied!" : "Copy Summary", systemImage: copiedNotice ? "checkmark" : "doc.on.doc")
                }
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 10)

            Picker("Tab", selection: $selectedTab) {
                Text("Image Details").tag(0)
                Text("Header Cards (\(header?.cards.count ?? 0))").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            if selectedTab == 0 {
                detailsView
            } else {
                rawHeaderView
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 540, idealWidth: 580, minHeight: 480, idealHeight: 540)
        #else
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Tab", selection: $selectedTab) {
                    Text("Image Details").tag(0)
                    Text("Header Cards (\(header?.cards.count ?? 0))").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)

                if selectedTab == 0 {
                    detailsView
                } else {
                    rawHeaderView
                }
            }
            .navigationTitle(model.fileName ?? "FITS Information")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        copySummaryToClipboard()
                    } label: {
                        Label(copiedNotice ? "Copied!" : "Copy Summary", systemImage: copiedNotice ? "checkmark" : "doc.on.doc")
                    }
                }
            }
        }
        #endif
    }

    // MARK: Details Tab

    private var detailsView: some View {
        List {
            if let image, let header {
                Section("Image Geometry") {
                    LabeledContent("Dimensions") {
                        Text("\(image.width) × \(image.height)")
                            .bold()
                    }
                    LabeledContent("Resolution") {
                        let mp = Double(image.width * image.height) / 1_000_000.0
                        Text(String(format: "%.2f Megapixels", mp))
                    }
                    LabeledContent("Channels") {
                        Text(image.channelCount == 1 ? "1 (Monochrome)" : "\(image.channelCount) (Color Cube)")
                    }
                    LabeledContent("Bit Depth") {
                        Text(bitpixDescription(header.bitpix))
                    }
                    if header.bzero != 0 || header.bscale != 1 {
                        LabeledContent("BZERO / BSCALE") {
                            Text(String(format: "%.1f / %.3f", header.bzero, header.bscale))
                        }
                    }
                }

                Section("Astrometry & Pointing") {
                    if let object = header.string("OBJECT") {
                        LabeledContent("Target Object") {
                            Text(object).bold()
                        }
                    }
                    if let ra = astrometry?.rightAscensionDegrees,
                       let dec = astrometry?.declinationDegrees {
                        LabeledContent("Right Ascension") {
                            Text(String(format: "%.4f° (%@)", ra, formatRA(ra)))
                        }
                        LabeledContent("Declination") {
                            Text(String(format: "%+.4f° (%@)", dec, formatDec(dec)))
                        }
                    } else {
                        LabeledContent("Pointing") {
                            Text("No celestial coordinates in header")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let date = astrometry?.observationDate {
                        LabeledContent("Observed (UTC)") {
                            Text(date, format: .dateTime.year().month().day().hour().minute().second().timeZone())
                        }
                    }
                    if let exp = astrometry?.exposureSeconds {
                        LabeledContent("Exposure Duration") {
                            Text(String(format: "%.1f seconds", exp))
                        }
                    }
                    if let scale = astrometry?.pixelScaleDegrees {
                        LabeledContent("Pixel Scale") {
                            Text(String(format: "%.3f″ / pixel", scale * 3600))
                        }
                        LabeledContent("Field of View") {
                            Text(String(format: "%.2f° × %.2f°",
                                         scale * Double(image.width),
                                         scale * Double(image.height)))
                        }
                    }
                    if let north = astrometry?.northAngleDegrees {
                        LabeledContent("Position Angle") {
                            Text(String(format: "%.1f° (North)", north))
                        }
                    }
                }

                if hasInstrumentInfo(header) {
                    Section("Instrument & Optics") {
                        if let telescope = header.string("TELESCOP") {
                            LabeledContent("Telescope / Rig", value: telescope)
                        }
                        if let focal = header.double("FOCALLEN"), focal > 0 {
                            LabeledContent("Focal Length") {
                                Text(String(format: "%.1f mm", focal))
                            }
                        }
                        if let camera = header.string("INSTRUME") ?? header.string("CAMERA") ?? header.string("DETECTOR") {
                            LabeledContent("Camera / Sensor", value: camera)
                        }
                        if let pixSize = header.double("XPIXSZ") {
                            LabeledContent("Pixel Size") {
                                Text(String(format: "%.2f µm", pixSize))
                            }
                        }
                        if let gain = header.string("GAIN") {
                            LabeledContent("Gain", value: gain)
                        }
                        if let filter = header.string("FILTER") {
                            LabeledContent("Filter", value: filter)
                        }
                    }
                }

                Section("Calculated Sky Position (at Observer Site)") {
                    LabeledContent("Observer Site") {
                        Text(String(format: "%.2f°N, %.2f°E", model.telemetry.latitude, model.telemetry.longitude))
                    }
                    LabeledContent("Target Altitude") {
                        Text(String(format: "%.1f° above horizon", model.telemetry.targetAltitudeDegrees))
                    }
                    LabeledContent("Target Azimuth") {
                        Text(String(format: "%.1f° heading", model.telemetry.targetAzimuthDegrees))
                    }
                }
            } else {
                ContentUnavailableView("No Image Loaded", systemImage: "doc.questionmark")
            }
        }
    }

    // MARK: Raw Header Tab

    private var rawHeaderView: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search keyword or value…", text: $searchKeyword)
                    .textFieldStyle(.plain)
                if !searchKeyword.isEmpty {
                    Button { searchKeyword = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)
            .padding(.bottom, 6)

            List {
                if let cards = header?.cards {
                    let filtered = searchKeyword.isEmpty ? cards : cards.filter {
                        $0.keyword.localizedCaseInsensitiveContains(searchKeyword) ||
                        ($0.value ?? "").localizedCaseInsensitiveContains(searchKeyword)
                    }

                    ForEach(Array(filtered.enumerated()), id: \.offset) { _, card in
                        HStack(alignment: .top) {
                            Text(card.keyword)
                                .font(.system(.body, design: .monospaced))
                                .bold()
                                .frame(width: 110, alignment: .leading)
                            Text(card.value ?? "")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private func bitpixDescription(_ bitpix: Int) -> String {
        switch bitpix {
        case 8: return "8-bit Unsigned Integer (BITPIX 8)"
        case 16: return "16-bit Signed Integer (BITPIX 16)"
        case 32: return "32-bit Signed Integer (BITPIX 32)"
        case 64: return "64-bit Signed Integer (BITPIX 64)"
        case -32: return "32-bit Single-Precision Float (BITPIX -32)"
        case -64: return "64-bit Double-Precision Float (BITPIX -64)"
        default: return "BITPIX \(bitpix)"
        }
    }

    private func hasInstrumentInfo(_ header: FITSHeader) -> Bool {
        header.string("TELESCOP") != nil ||
        header.double("FOCALLEN") != nil ||
        header.string("INSTRUME") != nil ||
        header.string("CAMERA") != nil ||
        header.string("FILTER") != nil
    }

    private func formatRA(_ deg: Double) -> String {
        let totalHours = deg / 15.0
        let h = Int(totalHours)
        let totalMinutes = (totalHours - Double(h)) * 60.0
        let m = Int(totalMinutes)
        let s = (totalMinutes - Double(m)) * 60.0
        return String(format: "%02dh %02dm %04.1fs", h, m, s)
    }

    private func formatDec(_ deg: Double) -> String {
        let sign = deg >= 0 ? "+" : "-"
        let absDeg = abs(deg)
        let d = Int(absDeg)
        let totalMinutes = (absDeg - Double(d)) * 60.0
        let m = Int(totalMinutes)
        let s = (totalMinutes - Double(m)) * 60.0
        return String(format: "%@%02d° %02d′ %04.1f″", sign, d, m, s)
    }

    private func copySummaryToClipboard() {
        guard let image, let header else { return }
        var summary = "=== FITS Information ===\n"
        summary += "File: \(model.fileName ?? "image.fits")\n"
        summary += "Dimensions: \(image.width) × \(image.height) (\(image.channelCount) channel(s))\n"
        summary += "Format: \(bitpixDescription(header.bitpix))\n"
        if let object = header.string("OBJECT") { summary += "Target: \(object)\n" }
        if let ra = astrometry?.rightAscensionDegrees, let dec = astrometry?.declinationDegrees {
            summary += String(format: "Coordinates: RA %.4f° (%@), Dec %+.4f° (%@)\n", ra, formatRA(ra), dec, formatDec(dec))
        }
        if let date = astrometry?.observationDate { summary += "Observation Date: \(date)\n" }
        if let exp = astrometry?.exposureSeconds { summary += "Exposure: \(exp)s\n" }
        if let scale = astrometry?.pixelScaleDegrees {
            summary += String(format: "Scale: %.3f″/px, FOV: %.2f° × %.2f°\n", scale * 3600, scale * Double(image.width), scale * Double(image.height))
        }

        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        #else
        UIPasteboard.general.string = summary
        #endif

        copiedNotice = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedNotice = false
        }
    }
}
