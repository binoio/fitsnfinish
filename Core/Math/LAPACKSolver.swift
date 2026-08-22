import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

public enum SolverError: Error, CustomStringConvertible {
    case dimensionMismatch
    case singularSystem
    case lapackFailure(code: Int)

    public var description: String {
        switch self {
        case .dimensionMismatch: return "Design matrix and observation vector sizes disagree"
        case .singularSystem: return "Least-squares system is singular"
        case .lapackFailure(let code): return "LAPACK dgels_ failed with info=\(code)"
        }
    }
}

/// Dense linear least-squares: minimizes ‖A·x − b‖₂ for an m×n matrix A
/// (row-major) with m ≥ n. Uses LAPACK `dgels_` (QR factorization) through
/// Accelerate on Apple platforms; falls back to solving the normal equations
/// with Gaussian elimination elsewhere (Linux CI containers).
public enum LAPACKSolver {
    public static func leastSquares(
        rowMajorA: [Double], rows m: Int, columns n: Int, b: [Double]
    ) throws -> [Double] {
        guard rowMajorA.count == m * n, b.count == m, m >= n, n > 0 else {
            throw SolverError.dimensionMismatch
        }
        #if canImport(Accelerate)
        return try dgelsLeastSquares(rowMajorA: rowMajorA, rows: m, columns: n, b: b)
        #else
        return try normalEquationsLeastSquares(rowMajorA: rowMajorA, rows: m, columns: n, b: b)
        #endif
    }

    #if canImport(Accelerate)
    private static func dgelsLeastSquares(
        rowMajorA: [Double], rows m: Int, columns n: Int, b: [Double]
    ) throws -> [Double] {
        // LAPACK expects column-major storage.
        var a = [Double](repeating: 0, count: m * n)
        for row in 0 ..< m {
            for column in 0 ..< n {
                a[column * m + row] = rowMajorA[row * n + column]
            }
        }
        var rhs = b

        var trans: Int8 = 78 // 'N'
        var mm = __CLPK_integer(m)
        var nn = __CLPK_integer(n)
        var nrhs = __CLPK_integer(1)
        var lda = __CLPK_integer(m)
        var ldb = __CLPK_integer(m)
        var info: __CLPK_integer = 0

        // Workspace query, then solve.
        var lwork = __CLPK_integer(-1)
        var workQuery = [Double](repeating: 0, count: 1)
        dgels_(&trans, &mm, &nn, &nrhs, &a, &lda, &rhs, &ldb, &workQuery, &lwork, &info)
        guard info == 0 else { throw SolverError.lapackFailure(code: Int(info)) }
        lwork = __CLPK_integer(workQuery[0])
        var work = [Double](repeating: 0, count: max(Int(lwork), 1))
        dgels_(&trans, &mm, &nn, &nrhs, &a, &lda, &rhs, &ldb, &work, &lwork, &info)
        guard info == 0 else { throw SolverError.lapackFailure(code: Int(info)) }

        return Array(rhs.prefix(n))
    }
    #endif

    /// Portable fallback: forms AᵀA x = Aᵀb and solves with partially
    /// pivoted Gaussian elimination. Adequate for the low-order (≤ 6
    /// coefficient) systems this app produces.
    static func normalEquationsLeastSquares(
        rowMajorA: [Double], rows m: Int, columns n: Int, b: [Double]
    ) throws -> [Double] {
        var ata = [Double](repeating: 0, count: n * n)
        var atb = [Double](repeating: 0, count: n)
        for row in 0 ..< m {
            let base = row * n
            for i in 0 ..< n {
                let ai = rowMajorA[base + i]
                atb[i] += ai * b[row]
                for j in i ..< n {
                    ata[i * n + j] += ai * rowMajorA[base + j]
                }
            }
        }
        for i in 0 ..< n {
            for j in 0 ..< i {
                ata[i * n + j] = ata[j * n + i]
            }
        }

        // Gaussian elimination with partial pivoting on [AᵀA | Aᵀb].
        var x = atb
        var matrix = ata
        for pivot in 0 ..< n {
            var maxRow = pivot
            var maxValue = abs(matrix[pivot * n + pivot])
            for row in (pivot + 1) ..< n where abs(matrix[row * n + pivot]) > maxValue {
                maxValue = abs(matrix[row * n + pivot])
                maxRow = row
            }
            guard maxValue > 1e-12 else { throw SolverError.singularSystem }
            if maxRow != pivot {
                for column in 0 ..< n {
                    matrix.swapAt(pivot * n + column, maxRow * n + column)
                }
                x.swapAt(pivot, maxRow)
            }
            for row in (pivot + 1) ..< n {
                let factor = matrix[row * n + pivot] / matrix[pivot * n + pivot]
                guard factor != 0 else { continue }
                for column in pivot ..< n {
                    matrix[row * n + column] -= factor * matrix[pivot * n + column]
                }
                x[row] -= factor * x[pivot]
            }
        }
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = x[row]
            for column in (row + 1) ..< n {
                sum -= matrix[row * n + column] * x[column]
            }
            x[row] = sum / matrix[row * n + row]
        }
        return x
    }
}
