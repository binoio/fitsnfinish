import Foundation

/// Low-order 2-D polynomial surface fitting.
///
/// Deliberately capped at degree 2: once the physics stage has removed the
/// non-linear airmass baseline, only gentle planar/quadratic residuals remain
/// (local light domes, flat-field residuals). Low-order surfaces lack the
/// freedom to conform to — and erase — real extended target flux.
public struct PolynomialFitter {
    public enum Degree: Int, CaseIterable, Identifiable {
        case linear = 1
        case quadratic = 2
        public var id: Int { rawValue }

        /// Number of coefficients: (d+1)(d+2)/2 monomials in x, y.
        public var termCount: Int { (rawValue + 1) * (rawValue + 2) / 2 }
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

        static func normalize(_ v: Int, extent: Int) -> Double {
            extent > 1 ? 2 * Double(v) / Double(extent - 1) - 1 : 0
        }
    }

    public var degree: Degree
    /// Sample grid spacing in pixels; the fitter samples the image on a
    /// coarse grid using per-cell medians so stars don't bias the background.
    public var sampleSpacing: Int

    public init(degree: Degree = .linear, sampleSpacing: Int = 8) {
        self.degree = degree
        self.sampleSpacing = max(1, sampleSpacing)
    }

    /// Monomial basis at a point: degree 1 → [1, x, y];
    /// degree 2 → [1, x, y, x², xy, y²].
    static func monomials(nx: Double, ny: Double, degree: Degree) -> [Double] {
        switch degree {
        case .linear: return [1, nx, ny]
        case .quadratic: return [1, nx, ny, nx * nx, nx * ny, ny * ny]
        }
    }

    /// Fits the background surface to `pixels` via least squares
    /// (LAPACK `dgels_` on Apple platforms).
    public func fit(pixels: [Float], width: Int, height: Int) throws -> Surface {
        precondition(pixels.count == width * height)
        var rows: [[Double]] = []
        var observations: [Double] = []

        var y = 0
        while y < height {
            var x = 0
            while x < width {
                // Median of the sample cell — robust against stars.
                var cell: [Float] = []
                let yEnd = min(y + sampleSpacing, height)
                let xEnd = min(x + sampleSpacing, width)
                for cy in y ..< yEnd {
                    for cx in x ..< xEnd {
                        cell.append(pixels[cy * width + cx])
                    }
                }
                cell.sort()
                let median = Double(cell[cell.count / 2])
                let cx = (x + xEnd - 1) / 2
                let cy = (y + yEnd - 1) / 2
                rows.append(Self.monomials(
                    nx: Surface.normalize(cx, extent: width),
                    ny: Surface.normalize(cy, extent: height),
                    degree: degree
                ))
                observations.append(median)
                x += sampleSpacing
            }
            y += sampleSpacing
        }

        let n = degree.termCount
        guard rows.count >= n else { throw SolverError.dimensionMismatch }
        let coefficients = try LAPACKSolver.leastSquares(
            rowMajorA: rows.flatMap { $0 },
            rows: rows.count,
            columns: n,
            b: observations
        )
        return Surface(degree: degree, coefficients: coefficients, width: width, height: height)
    }

    /// Fits and subtracts the surface, preserving the mean background level
    /// and clamping the black point at zero.
    public func removeBackground(
        pixels: [Float], width: Int, height: Int
    ) throws -> [Float] {
        let surface = try fit(pixels: pixels, width: width, height: height)
        let rendered = surface.render()
        let mean = rendered.reduce(0, +) / Float(rendered.count)
        var out = [Float](repeating: 0, count: pixels.count)
        for k in 0 ..< pixels.count {
            out[k] = max(pixels[k] - (rendered[k] - mean), 0)
        }
        return out
    }
}
