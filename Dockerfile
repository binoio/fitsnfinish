# Containerized test run for the portable core (FITS parsing, physics,
# polynomial fitting, telemetry assembly). Apple-only frameworks
# (Accelerate, Metal, WeatherKit, CoreLocation, SwiftUI) are compiled out on
# Linux via canImport/os guards; the solver exercises its portable fallback.
FROM swift:6.1-noble

RUN apt-get update && apt-get install -y --no-install-recommends zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /package
COPY Package.swift ./
COPY CZLib ./CZLib
COPY Core ./Core
COPY CLI ./CLI
COPY Tests ./Tests

CMD ["swift", "test"]
