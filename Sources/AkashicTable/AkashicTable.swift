import Foundation

public protocol RowIdentifiable {
    var rowId: Int64 { get }
}

public final class AkashicTable<T: RowIdentifiable>: RandomAccessCollection, ContiguousBytes, MutableCollection {
    public enum AkashicTableError: LocalizedError {
        case ioError(String)
        case validationFailed(String)

        public var errorDescription: String? {
            switch self {
            case let .ioError(text):
                "IO Error: \(text)"
            case let .validationFailed(text):
                "Validation Error: \(text)"
            }
        }
    }

    public struct AkashicTableIterator: IteratorProtocol {
        private let buffer: UnsafeMutableRawPointer
        private let step: Int
        private let end: Int

        private var position: Int

        fileprivate init(buffer: UnsafeMutableRawPointer, stride: Int, counterSize: Int) {
            self.buffer = buffer
            position = counterSize
            step = stride
            end = counterSize + buffer.loadUnaligned(as: Int.self) * stride
        }

        public mutating func next() -> T? {
            if position == end {
                return nil
            }
            defer {
                position += step
            }
            return buffer.loadUnaligned(fromByteOffset: position, as: T.self)
        }
    }

    private let step = MemoryLayout<T>.stride
    private let counterSize = MemoryLayout<Int>.stride

    public var count: Int {
        get {
            buffer!.loadUnaligned(as: Int.self)
        }
        set {
            buffer!.storeBytes(of: newValue, as: Int.self)
        }
    }

    public let startIndex = 0
    public var endIndex: Int { count }

    private var capacity = 0
    private var fileDescriptor: Int32 = 0
    private var buffer: UnsafeMutableRawPointer?
    private var mappedSize = 0
    private let path: String
    private let useCache: Bool

    public func index(after i: Int) -> Int { i + 1 }

    @inline(__always)
    private func offset(for index: Int) -> Int {
        counterSize + step * index
    }

    public init(at path: String, minimumCapacity: Int, useCache: Bool = true, validateOrder: Bool = false) throws {
        self.path = path
        self.useCache = useCache

        try start(minimumCapacity: minimumCapacity)

        if validateOrder {
            try runValidation()
        }
    }

    private func runValidation() throws {
        print("Validating memory mapped collection…")
        var previousRowId: Int64?
        for row in self {
            let rowId = row.rowId
            if let previousRowId, rowId <= previousRowId {
                if rowId == previousRowId {
                    throw AkashicTableError.validationFailed("Duplicate row ID [\(rowId)]")
                } else {
                    throw AkashicTableError.validationFailed("Rows are not sorted by rowId - [\(rowId)] came after [\(previousRowId)]")
                }
            }
            previousRowId = rowId
        }
        print("Validation complete - checked \(count) records")
    }

    public func append(_ item: T) throws {
        try append(contentsOf: [item])
    }

    private func index(for rowId: Int64) -> Int? {
        guard let buffer else { return nil }

        var lowerIndex = 0
        var upperIndex = count - 1

        while true {
            if lowerIndex > upperIndex {
                return nil
            }
            let currentIndex = (lowerIndex + upperIndex) / 2
            let currentRowId = buffer.loadUnaligned(fromByteOffset: offset(for: currentIndex), as: Int64.self)
            if currentRowId == rowId {
                return currentIndex
            } else if currentRowId > rowId {
                upperIndex = currentIndex - 1
            } else {
                lowerIndex = currentIndex + 1
            }
        }
    }

    public func append(contentsOf sequence: any Collection<T>) throws {
        var currentCount = count
        let newMaxCount = currentCount + sequence.count
        if newMaxCount >= capacity {
            try start(minimumCapacity: newMaxCount + 10000)
        }

        let originalCount = currentCount
        for item in sequence {
            if let existingIndex = index(for: item.rowId) {
                self[existingIndex] = item
            } else {
                var newItemIndex = currentCount
                var previousIndex = newItemIndex - 1
                currentCount += 1

                self[newItemIndex] = item

                while newItemIndex > 0, item.rowId < self[previousIndex].rowId {
                    let previous = self[previousIndex]
                    self[previousIndex] = self[newItemIndex]
                    self[newItemIndex] = previous
                    newItemIndex -= 1
                    previousIndex -= 1
                }
            }
        }

        if originalCount != currentCount {
            count = currentCount
        }
    }

    public func deleteEntries(with ids: Set<Int64>) {
        // fast-iterating version of deleteAll without a block capture
        var pos = count - 1
        while pos >= 0 {
            if ids.contains(self[pos].rowId) {
                delete(at: pos)
            }
            pos -= 1
        }
    }

    public func deleteAll(where condition: (T) -> Bool) {
        var pos = count - 1
        while pos >= 0 {
            if condition(self[pos]) {
                delete(at: pos)
            }
            pos -= 1
        }
    }

    public func makeIterator() -> AkashicTableIterator {
        AkashicTableIterator(buffer: buffer!, stride: step, counterSize: counterSize)
    }

    public func delete(at index: Int) {
        guard let buffer else { return }

        let existingCount = count
        if index >= existingCount {
            return
        }

        let highestIndex = existingCount - 1
        if index == highestIndex {
            count -= 1
            return
        }

        let itemOffset = offset(for: index)
        let highestItemOffset = offset(for: highestIndex)
        let byteCount = highestItemOffset - itemOffset
        buffer.advanced(by: itemOffset).copyMemory(from: buffer.advanced(by: itemOffset + step), byteCount: byteCount)
        count -= 1
    }

    public subscript(position: Int) -> T {
        get {
            buffer!.loadUnaligned(fromByteOffset: offset(for: position), as: T.self)
        }
        set {
            buffer!.storeBytes(of: newValue, toByteOffset: offset(for: position), as: T.self)
        }
    }

    private func start(minimumCapacity: Int) throws {
        if buffer != nil {
            shutdown()
        }

        fileDescriptor = open(path, O_CREAT | O_RDWR, S_IREAD | S_IWRITE)
        if fileDescriptor == 0 {
            throw AkashicTableError.ioError("Could not create or open file at \(path)")
        }

        var statInfo = stat()
        if fstat(fileDescriptor, &statInfo) != 0 {
            throw AkashicTableError.ioError("Cannot access backing file on disk")
        }

        let minimumSize = offset(for: minimumCapacity)
        let pageSize = Int(getpagesize())
        let targetSize = ((minimumSize + pageSize - 1) / pageSize) * pageSize
        let existingSize = Int(statInfo.st_size)

        if targetSize > existingSize {
            if ftruncate(fileDescriptor, off_t(targetSize)) != 0 {
                throw AkashicTableError.ioError("Cannot resize backing file on disk")
            }
            mappedSize = targetSize
        } else {
            mappedSize = existingSize
        }

        capacity = (mappedSize - counterSize) / step

        let access = PROT_READ | PROT_WRITE
        var flags = MAP_SHARED
        if !useCache {
            flags |= MAP_NOCACHE
        }
        buffer = mmap(nil, mappedSize, access, flags, fileDescriptor, 0)

        if buffer == nil {
            close(fileDescriptor)
            throw AkashicTableError.ioError("Cannot map backing file on disk")
        }

        // print("Memory mapped index size: \(Double(mappedSize) / 1_000_000_000) Gb")
    }

    public func shutdown() {
        guard let buf = buffer else {
            return
        }
        msync(buf, mappedSize, 0)
        munmap(buf, mappedSize)
        buffer = nil
        mappedSize = 0
        close(fileDescriptor)
    }

    deinit {
        shutdown()
    }

    public func resume() throws {
        try start(minimumCapacity: 0)
    }

    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        let bufferPointer = UnsafeRawBufferPointer(start: buffer!, count: count)
        return try body(bufferPointer)
    }
}
