import Foundation

protocol DirectionEngine {
    func stream() -> AsyncStream<DirectionSample>
}
