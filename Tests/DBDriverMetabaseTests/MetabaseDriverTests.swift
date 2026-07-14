import Testing

@testable import DBDriverMetabase

@Suite struct MetabaseDriverTests {
    @Test func descriptorID() {
        #expect(MetabaseDriver.descriptor.id == "metabase")
    }
}
