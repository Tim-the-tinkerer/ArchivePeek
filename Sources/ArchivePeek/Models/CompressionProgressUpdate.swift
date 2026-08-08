import Foundation

struct CompressionProgressUpdate: Sendable {
    let fraction: Double
    let message: String
    let indeterminate: Bool

    init(fraction: Double, message: String, indeterminate: Bool = false) {
        self.fraction = fraction
        self.message = message
        self.indeterminate = indeterminate
    }
}