import Foundation

/// Low-order 2-D polynomial surface fitting.
///
/// Deliberately capped at degree 2: once the physics stage has removed the
/// non-linear airmass baseline, only gentle planar/quadratic residuals remain
/// (local light domes, flat-field residuals). Low-order surfaces lack the
/// freedom to conform to — and erase — real extended target flux.
///
/// Robustness comes from three layers:
/// 1. per-cell **medians**, immune to point sources;
/// 2. an explicit **bright-star mask** — pixels above a sigma threshold are
///    excluded, and cells dominated by masked pixels (plus a dilation ring
///    around them, covering halos of saturated stars) are dropped entirely;
/// 3. **sigma-clipped refitting** — cells whose median disagrees with the
///    fitted surface beyond `clipSigma` robust deviations are discarded and
///    the surface refit, so large halos cannot tilt the fit.
public struct PolynomialFitter {
    public enum Degree: Int, CaseIterable, Identifiable {
        case linear = 1
        case quadratic = 2
        public var id: Int { rawValue }

        /// Number of coefficients: (d+1)(d+2)/2 monomials in x, y.
        public var termCount: Int { (rawValue + 1) * (rawValue + 2) / 2 }
    }

    /// One background sample: a cell-median value at a pixel position.
    public struct CellSample {
        public let x: Int
        public let y: Int
        public let value: Double

        public init(x: Int, y: Int, value: Double) {
            self.x = x
            self.y = y
            self.value = value
        }
    }

    /// A fitted surface: evaluate with normalized coordinates in [-1, 1].
    public struct Surface {
        public let degree: Degree
        public let coefficients: [Double]
        let width: Int
        let height: Int

        /// Evaluates the surface at pixel (x, y).
        public func value(x: Int, y: Int) -> Double {
            let nx = Surface.normalize(x, extent: width)
            let ny = Surface.normalize(y, extent: height)
            let terms = PolynomialFitter.monomials(nx: nx, ny: ny, degree: degree)
            return zip(terms, coefficients).reduce(0) { $0 + $1.0 * $1.1 }
        }

        /// Renders the full surface as row-major floats.
        public func render() -> [Float] {
            var out = [Float](repeating: 0, count: width * height)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    out[y * width + x] = Float(value(x: x, y: y))
                }
            }
            return out
        }

        /// Exact mean of the surface over the pixel grid, in O(W + H): odd
        /// monomials average to zero on the symmetric normalized grid, so
        /// only the constant and squared terms contribute.
        public func gridMean() -> Double {
            var mean = coefficients[0]
            if degree == .quadratic {
                mean += coefficients[3] * Surface.meanSquare(extent: width)
                mean += coefficients[5] * Surface.meanSquare(extent: height)
            }
            return mean
        }

        static func normalize(_ v: Int, extent: Int) -> Double {
            extent > 1 ? 2 * Double(v) / Double(extent - 1) - 1 : 0
        }

        static func meanSquare(extent: Int) -> Double {
            guard extent > 1 else { return 0 }
            var sum = 0.0
            for v in 0 ..< extent {
                let n = normalize(v, extent: extent)
                sum += n * n
            }
            return sum / Double(extent)
        }
    }

    public var degree: Degree
    /// Sample grid spacing in pixels; the fitter samples the image on a
    /// coarse grid using per-cell medians so stars don't bias the background.
    public var sampleSpacing: Int
    /// Pixels above (median + maskSigma·σ) are treated as stars and excluded
    /// from cell medians.
    public var maskSigma: Double
    /// A cell is dropped when more than this fraction of its pixels is
    /// masked (star-dominated cell).
    public var maxMaskedFraction: Double
    /// Cells within this Chebyshev distance of a dropped cell are dropped
    /// too, excluding the halo ring around saturated stars.
    public var haloCellDilation: Int
    /// Sigma-clip threshold for iterative refitting of cell medians.
    public var clipSigma: Double
    /// Maximum sigma-clip refit iterations.
    public var clipIterations: Int

    public init(
        degree: Degree = .linear,
        sampleSpacing: Int = 8,
        maskSigma: Double = 5,
        maxMaskedFraction: Double = 0.5,
        haloCellDilation: Int = 1,
        clipSigma: Double = 3,
        clipIterations: Int = 3
    ) {
        self.degree = degree
        self.sampleSpacing = max(1, sampleSpacing)
        self.maskSigma = maskSigma
        self.maxMaskedFraction = maxMaskedFraction
        self.haloCellDilation = max(0, haloCellDilation)
        self.clipSigma = clipSigma
        self.clipIterations = max(0, clipIterations)
    }

    /// Monomial basis at a point: degree 1 → [1, x, y];
    /// degree 2 → [1, x, y, x², xy, y²].
    static func monomials(nx: Double, ny: Double, degree: Degree) -> [Double] {
        switch degree {
        case .linear: return [1, nx, ny]
        case .quadratic: return [1, nx, ny, nx * nx, nx * ny, ny * ny]
        }
    }

    /// Robust image statistics (median and MAD-σ) from strided sampling.
    public static func robustStatistics(
        of pixels: [Float], sampleLimit: Int = 100_000
    ) -> (median: Double, sigma: Double) {
        let stride = max(1, pixels.count / sampleLimit)
        var sample: [Float] = []
        sample.reserveCapacity(pixels.count / stride + 1)
        var k = 0
        while k < pixels.count {
            sample.append(pixels[k])
            k += stride
        }
        sample.sort()
        let median = Double(sample[sample.count / 2])
        var deviations = sample.map { abs(Double($0) - median) }
        deviations.sort()
        let mad = deviations[deviations.count / 2]
        return (median, 1.4826 * mad)
    }

    /// The bright-pixel threshold used by the star mask.
    public func brightThreshold(for pixels: [Float]) -> Float {
        let stats = Self.robustStatistics(of: pixels)
        return Float(stats.median + maskSigma * stats.sigma)
    }

    /// Collects masked cell-median samples from the image: per-cell medians
    /// over unmasked pixels, with star-dominated cells and their halo ring
    /// removed.
    public func collectSamples(
        pixels: [Float], width: Int, height: Int
    ) -> [CellSample] {
        let threshold = brightThreshold(for: pixels)
        let cellsX = (width + sampleSpacing - 1) / sampleSpacing
        let cellsY = (height + sampleSpacing - 1) / sampleSpacing
        var medians = [Double](repeating: 0, count: cellsX * cellsY)
        var maskedFractions = [Double](repeating: 0, count: cellsX * cellsY)

        for cy in 0 ..< cellsY {
            for cx in 0 ..< cellsX {
                let x0 = cx * sampleSpacing
                let y0 = cy * sampleSpacing
                let x1 = min(x0 + sampleSpacing, width)
                let y1 = min(y0 + sampleSpacing, height)
                var kept: [Float] = []
                var total = 0
                for y in y0 ..< y1 {
                    for x in x0 ..< x1 {
                        let value = pixels[y * width + x]
                        total += 1
                        if value <= threshold { kept.append(value) }
                    }
                }
                let cell = cy * cellsX + cx
                maskedFractions[cell] = 1 - Double(kept.count) / Double(total)
                if !kept.isEmpty {
                    kept.sort()
                    medians[cell] = Double(kept[kept.count / 2])
                }
            }
        }

        return assembleSamples(
            cellMedians: medians, maskedFractions: maskedFractions,
            cellsX: cellsX, cellsY: cellsY, width: width, height: height
        )
    }

    /// Turns per-cell (median, masked fraction) grids — computed on CPU or
    /// GPU — into fit samples: star-dominated cells are dropped and the halo
    /// ring around each dropped cell is dilated away.
    public func assembleSamples(
        cellMedians: [Double], maskedFractions: [Double],
        cellsX: Int, cellsY: Int, width: Int, height: Int
    ) -> [CellSample] {
        var dropped = maskedFractions.map { $0 > maxMaskedFraction }

        if haloCellDilation > 0 {
            let starDominated = dropped
            for cy in 0 ..< cellsY {
                for cx in 0 ..< cellsX where starDominated[cy * cellsX + cx] {
                    for dy in -haloCellDilation ... haloCellDilation {
                        for dx in -haloCellDilation ... haloCellDilation {
                            let nx = cx + dx
                            let ny = cy + dy
                            if nx >= 0, nx < cellsX, ny >= 0, ny < cellsY {
                                dropped[ny * cellsX + nx] = true
                            }
                        }
                    }
                }
            }
        }

        var samples: [CellSample] = []
        samples.reserveCapacity(cellsX * cellsY)
        for cy in 0 ..< cellsY {
            for cx in 0 ..< cellsX where !dropped[cy * cellsX + cx] {
                let x0 = cx * sampleSpacing
                let y0 = cy * sampleSpacing
                let x1 = min(x0 + sampleSpacing, width)
                let y1 = min(y0 + sampleSpacing, height)
                samples.append(CellSample(
                    x: (x0 + x1 - 1) / 2,
                    y: (y0 + y1 - 1) / 2,
                    value: cellMedians[cy * cellsX + cx]
                ))
            }
        }
        return samples
    }

    /// Fits the surface to pre-collected samples with sigma-clipped
    /// iteration. This is the shared solve used by both the CPU path
    /// (`fit(pixels:...)`) and the GPU cell-median path.
    public func fit(
        samples initialSamples: [CellSample], width: Int, height: Int
    ) throws -> Surface {
        let terms = degree.termCount
        var samples = initialSamples
        guard samples.count >= terms else { throw SolverError.dimensionMismatch }

        var surface = try solve(samples: samples, width: width, height: height)
        for _ in 0 ..< clipIterations {
            let residuals = samples.map { $0.value - surface.value(x: $0.x, y: $0.y) }
            var deviations = residuals.map { abs($0) }
            deviations.sort()
            let sigma = 1.4826 * deviations[deviations.count / 2]
            // A perfectly consistent set has nothing left to clip.
            guard sigma > 1e-6 else { break }
            let kept = zip(samples, residuals)
                .filter { abs($0.1) <= clipSigma * sigma }
                .map { $0.0 }
            guard kept.count >= max(terms, samples.count / 4) else { break }
            if kept.count == samples.count { break }
            samples = kept
            surface = try solve(samples: samples, width: width, height: height)
        }
        return surface
    }

    private func solve(
        samples: [CellSample], width: Int, height: Int
    ) throws -> Surface {
        let terms = degree.termCount
        var rows: [Double] = []
        rows.reserveCapacity(samples.count * terms)
        var observations: [Double] = []
        observations.reserveCapacity(samples.count)
        for sample in samples {
            rows.append(contentsOf: Self.monomials(
                nx: Surface.normalize(sample.x, extent: width),
                ny: Surface.normalize(sample.y, extent: height),
                degree: degree
            ))
            observations.append(sample.value)
        }
        let coefficients = try LAPACKSolver.leastSquares(
            rowMajorA: rows, rows: samples.count, columns: terms, b: observations
        )
        return Surface(degree: degree, coefficients: coefficients, width: width, height: height)
    }

    /// Fits the background surface to `pixels` via masked cell medians and
    /// sigma-clipped least squares (LAPACK `dgels_` on Apple platforms).
    public func fit(pixels: [Float], width: Int, height: Int) throws -> Surface {
        precondition(pixels.count == width * height)
        return try fit(
            samples: collectSamples(pixels: pixels, width: width, height: height),
            width: width, height: height
        )
    }

    /// Fits and subtracts the surface, preserving the mean background level
    /// and clamping the black point at zero.
    public func removeBackground(
        pixels: [Float], width: Int, height: Int
    ) throws -> [Float] {
        let surface = try fit(pixels: pixels, width: width, height: height)
        let rendered = surface.render()
        let mean = Float(surface.gridMean())
        var out = [Float](repeating: 0, count: pixels.count)
        for k in 0 ..< pixels.count {
            out[k] = max(pixels[k] - (rendered[k] - mean), 0)
        }
        return out
    }
}
