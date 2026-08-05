import Foundation

extension Array where Element == Float {
    /// Little-endian raw bytes of the float array.
    var dataLE: Data {
        withUnsafeBufferPointer { Data(buffer: $0) }
    }
    init(dataLE data: Data) {
        let count = data.count / MemoryLayout<Float>.stride
        self = data.withUnsafeBytes { raw in
            Array(UnsafeBufferPointer(start: raw.bindMemory(to: Float.self).baseAddress, count: count))
        }
    }
}
