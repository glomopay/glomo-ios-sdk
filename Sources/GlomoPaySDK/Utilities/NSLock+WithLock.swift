import Foundation

extension NSLock {
    func glomoWithLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
