@testable import AkashicTable
import Foundation
import Testing

struct TestType: RowIdentifiable, Equatable {
    let rowId: Int64

    let data = (0, 1, 2, 3, 4, 5, 6, 7, 8, 9)

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rowId == rhs.rowId
    }
}

@Test func test() async throws {
    let fm = FileManager.default
    let embeddingPath = fm.temporaryDirectory.appending(path: "test.embeddings", directoryHint: .notDirectory).path

    if fm.fileExists(atPath: embeddingPath) {
        _ = try? fm.removeItem(atPath: embeddingPath)
    }

    let collection = try AkashicTable<TestType>(at: embeddingPath, minimumCapacity: 10, validateOrder: true)

    for i in 0 ..< 100 {
        let item = TestType(rowId: Int64(i))
        try! collection.append(item)
    }

    #expect(collection.count == 100)
    #expect(collection.first?.rowId == 0)
    #expect(collection.last?.rowId == 99)
    #expect(collection.first(where: { $0.rowId == 50 })?.rowId == 50)
    #expect(collection.firstIndex(of: TestType(rowId: 50)) == 50)

    for _ in 0 ..< 25 {
        collection.delete(at: 0)
    }
    #expect(collection.count == 75)
    #expect(collection.first?.rowId == 25)
    #expect(collection.last?.rowId == 99)

    collection.delete(at: 74)
    #expect(collection.count == 74)
    #expect(collection.first?.rowId == 25)
    #expect(collection.last?.rowId == 98)
    collection.delete(at: 0)
    #expect(collection.first?.rowId == 26)
    #expect(collection.last?.rowId == 98)

    try! collection.append(TestType(rowId: 10))
    try! collection.append(TestType(rowId: 11))
    try! collection.append(TestType(rowId: 97))
    #expect(collection.first?.rowId == 10)
    #expect(collection.last?.rowId == 98)
    try! collection.append(TestType(rowId: 97))
    #expect(collection.last?.rowId == 98)
    try! collection.append(TestType(rowId: 99))
    #expect(collection.last?.rowId == 99)

    #expect(collection.first(where: { $0.rowId == 3 }) == nil)
    #expect(collection.first(where: { $0.rowId == 11 }) != nil)

    #expect(collection.count == 76)
    collection.deleteEntries(with: [3, 11, 97])
    #expect(collection.count == 74)

    #expect(collection.first(where: { $0.rowId == 97 }) == nil)

    let ids = collection.map(\.rowId)
    #expect(ids[0 ..< 10] == [10, 26, 27, 28, 29, 30, 31, 32, 33, 34])

    collection.shutdown()

    let collection2 = try AkashicTable<TestType>(at: embeddingPath, minimumCapacity: 10, validateOrder: true)
    #expect(collection2[0 ..< 10].map(\.rowId) == [10, 26, 27, 28, 29, 30, 31, 32, 33, 34])
    collection2.shutdown()
}
