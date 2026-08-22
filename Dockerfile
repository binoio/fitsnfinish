# Containerized test run for the portable core (FITS parsing, physics,
# polynomial fitting, telemetry assembly). Apple-only frameworks
# (Accelerate, Metal, WeatherKit, CoreLocation, SwiftUI) are compiled out on
# Linux via canImport/os guards; the solver exercises its portable fallback.
FROM swift:6.1-noble

WORKDIR /package
COPY Package.swift ./
COPY Core ./Core
COPY Tests ./Tests

CMD ["swift", "test"]
