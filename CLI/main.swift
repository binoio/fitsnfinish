import Foundation
import FitsnFinishCore

// fnfin: headless FITS n' Finish. The CPU reference pipeline over the same
// Core the apps use — for stacking-pipeline integration and scripting.

let fnfinVersion = "0.4.2"

func printUsage() {
    print("""
    fnfin — physics-first gradient removal for astrophotography

    USAGE
      fnfin process [options] <file.fit ...>   remove gradients, write *_finished.fits
      fnfin info <file.fit ...>                print image and pointing information
      fnfin --version

    PROCESS OPTIONS
      --degree 1|2           surface degree (default 1)
      --strength <f>         physics strength multiplier (default 1.0)
      --preset <file.json>   apply a preset file (site + engine settings)
      --lat <deg>            observer latitude  (default 0 or preset)
      --lon <deg>            observer longitude (default 0 or preset)
      --no-header-astrometry ignore WCS/RA/Dec/DATE-OBS in the file
      --output <dir>         write results into this directory
      --suffix <text>        output name suffix (default "_finished")

    Header astrometry (plate solution, capture time, optics) is applied by
    default; a preset supplies site coordinates and engine settings. Output
    is 16-bit FITS with WCS and provenance cards preserved.
    """)
}

struct Options {
    var degree = PolynomialFitter.Degree.linear
    var strength: Float = 1
    var preset: ProcessingPreset?
    var latitude: Double?
    var longitude: Double?
    var useHeaderAstrometry = true
    var outputDirectory: String?
    var suffix = "_finished"
    var files: [String] = []
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("fnfin: \(message)\n".utf8))
    exit(1)
}

func parseOptions(_ arguments: [String]) -> Options {
    var options = Options()
    var iterator = arguments.makeIterator()
    func value(_ flag: String) -> String {
        guard let v = iterator.next() else { fail("missing value for \(flag)") }
        return v
    }
    while let argument = iterator.next() {
        switch argument {
        case "--degree":
            let raw = value(argument)
            guard let d = Int(raw), let degree = PolynomialFitter.Degree(rawValue: d) else {
                fail("--degree must be 1 or 2")
            }
            options.degree = degree
        case "--strength":
            guard let s = Float(value(argument)) else { fail("--strength needs a number") }
            options.strength = s
        case "--preset":
            let path = value(argument)
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                guard let preset = try JSONDecoder().decode([ProcessingPreset].self, from: data).first else {
                    fail("preset file \(path) contains no presets")
                }
                options.preset = preset
            } catch {
                fail("cannot read preset \(path): \(error.localizedDescription)")
            }
        case "--lat":
            guard let v = Double(value(argument)) else { fail("--lat needs a number") }
            options.latitude = v
        case "--lon":
            guard let v = Double(value(argument)) else { fail("--lon needs a number") }
            options.longitude = v
        case "--no-header-astrometry":
            options.useHeaderAstrometry = false
        case "--output":
            options.outputDirectory = value(argument)
        case "--suffix":
            options.suffix = value(argument)
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            if argument.hasPrefix("-") { fail("unknown option \(argument)") }
            options.files.append(argument)
        }
    }
    return options
}

func telemetry(for image: FITSImage, options: Options) -> TelemetrySnapshot {
    var telemetry = TelemetrySnapshot()
    if let preset = options.preset {
        telemetry = preset.applied(to: telemetry)
    }
    if let lat = options.latitude { telemetry.latitude = lat }
    if let lon = options.longitude { telemetry.longitude = lon }
    guard options.useHeaderAstrometry else { return telemetry }

    let astrometry = HeaderAstrometry(header: image.header)
    if let scale = astrometry.pixelScaleDegrees {
        telemetry.fieldOfViewDegrees = scale * Double(image.width)
    }
    if let date = astrometry.observationDate {
        telemetry.observationDate = date
        telemetry.exposureSeconds = astrometry.exposureSeconds ?? 0
    }
    if let ra = astrometry.rightAscensionDegrees,
       let dec = astrometry.declinationDegrees {
        telemetry.rightAscensionDegrees = ra
        telemetry.declinationDegrees = dec
        if let date = telemetry.observationDate {
            let position = Astrometry.horizontal(
                rightAscensionDegrees: ra, declinationDegrees: dec,
                latitude: telemetry.latitude, longitude: telemetry.longitude,
                date: date
            )
            telemetry.targetAltitudeDegrees = position.altitudeDegrees
            telemetry.targetAzimuthDegrees = position.azimuthDegrees
        }
    }
    return telemetry
}

func outputURL(for input: URL, options: Options) -> URL {
    let base = input.deletingPathExtension().lastPathComponent + options.suffix
    let directory = options.outputDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? input.deletingLastPathComponent()
    return directory.appendingPathComponent(base).appendingPathExtension("fits")
}

func runProcess(_ arguments: [String]) {
    let options = parseOptions(arguments)
    guard !options.files.isEmpty else {
        printUsage()
        exit(1)
    }
    if let directory = options.outputDirectory {
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
    }
    var failures = 0
    for path in options.files {
        let input = URL(fileURLWithPath: path)
        do {
            let image = try FITSReader.read(contentsOf: input)
            let pipeline = GradientRemovalPipeline(
                telemetry: telemetry(for: image, options: options),
                degree: options.degree,
                physicsStrength: options.strength
            )
            let results = try pipeline.processPlanes(image: image)
            let output = outputURL(for: input, options: options)
            let data = FITSWriter.data(
                planes: results.map { $0.pixels },
                width: image.width, height: image.height,
                preservingFrom: image.header
            )
            try data.write(to: output)
            print("\(input.lastPathComponent) → \(output.lastPathComponent)"
                  + " (\(image.width)×\(image.height), \(image.channelCount) ch,"
                  + " degree \(options.degree.rawValue))")
        } catch {
            failures += 1
            FileHandle.standardError.write(
                Data("fnfin: \(input.lastPathComponent): \(error)\n".utf8)
            )
        }
    }
    exit(failures == 0 ? 0 : 1)
}

func runInfo(_ arguments: [String]) {
    guard !arguments.isEmpty else {
        printUsage()
        exit(1)
    }
    for path in arguments {
        do {
            let image = try FITSReader.read(contentsOf: URL(fileURLWithPath: path))
            let astrometry = HeaderAstrometry(header: image.header)
            print("\(path):")
            print("  size      \(image.width)×\(image.height), \(image.channelCount) channel(s), BITPIX \(image.header.bitpix)")
            if let ra = astrometry.rightAscensionDegrees,
               let dec = astrometry.declinationDegrees {
                print(String(format: "  pointing  RA %.4f°, Dec %+.4f°", ra, dec))
            }
            if let date = astrometry.observationDate {
                print("  captured  \(date) (exposure \(astrometry.exposureSeconds ?? 0)s)")
            }
            if let scale = astrometry.pixelScaleDegrees {
                print(String(format: "  scale     %.3f″/px, field %.2f°×%.2f°",
                             scale * 3600,
                             scale * Double(image.width),
                             scale * Double(image.height)))
            }
        } catch {
            FileHandle.standardError.write(Data("fnfin: \(path): \(error)\n".utf8))
            exit(1)
        }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "process":
    runProcess(Array(arguments.dropFirst()))
case "info":
    runInfo(Array(arguments.dropFirst()))
case "--version", "-V":
    print("fnfin \(fnfinVersion)")
case "--help", "-h", .none:
    printUsage()
default:
    fail("unknown command \(arguments[0]); try fnfin --help")
}
