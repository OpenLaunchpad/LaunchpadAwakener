import Foundation
import MachO
@testable import LaunchpadAwakenerPayloadCore
import Testing

/// Finding a host's singleton by what its globals hold.
///
/// The scanner takes the regions to walk as a parameter, so these tests hand it a block they allocated
/// themselves rather than injecting anything into the Dock: everything that decides the outcome — how a
/// candidate is accepted, what several hits mean, which section answers first — is a computation over
/// memory, and can be driven from a test process. Only the last test touches real sections, and it
/// walks this test process's own.
@Suite("Finding a host's globals by class")
struct DockGlobalScannerTests {
    /// Stands in for one of the Dock's singletons.
    private final class StandInSingleton {
        let identifier: Int

        init(identifier: Int) {
            self.identifier = identifier
        }
    }

    /// A different class of the same shape, to prove the class comparison is what decides.
    private final class UnrelatedStandIn {
        let identifier: Int

        init(identifier: Int) {
            self.identifier = identifier
        }
    }

    /// A block of pointer slots a test fills in, standing in for a section of the host's `__DATA`.
    ///
    /// Allocated pointer-aligned and zeroed, which is how the linker leaves `__common` before the host
    /// writes to it.
    private final class StandInSection {
        let region: PointerSlotRegion
        private let storage: UnsafeMutableBufferPointer<UnsafeRawPointer?>

        init(slotCount: Int, name: String = "__DATA,__common") {
            storage = .allocate(capacity: slotCount)
            storage.initialize(repeating: nil)
            region = PointerSlotRegion(
                baseAddress: UnsafeRawPointer(storage.baseAddress!),
                byteCount: slotCount * MemoryLayout<UnsafeRawPointer>.size,
                name: name
            )
        }

        deinit {
            storage.deallocate()
        }

        /// Puts `object` in one slot, the way the Dock's own code assigns to its global.
        ///
        /// Unretained on purpose: the caller keeps the object alive for the length of the test, exactly
        /// as the Dock outlives the singleton reads the payload makes.
        func put(_ object: AnyObject, inSlot slotIndex: Int) {
            storage[slotIndex] = UnsafeRawPointer(Unmanaged.passUnretained(object).toOpaque())
        }

        /// Puts a value that is not a heap block at all in one slot.
        func putNonHeapValue(_ value: UInt, inSlot slotIndex: Int) {
            storage[slotIndex] = UnsafeRawPointer(bitPattern: value)
        }

        func slotAddress(_ slotIndex: Int) -> UnsafeRawPointer {
            region.baseAddress.advanced(by: slotIndex * MemoryLayout<UnsafeRawPointer>.size)
        }
    }

    // MARK: - Accepting a slot

    @Test("the slot holding an instance of the class is found")
    func findsTheSlotHoldingAnInstance() throws {
        let singleton = StandInSingleton(identifier: 1)
        let section = StandInSection(slotCount: 64)
        section.put(singleton, inSlot: 17)

        let outcome = DockGlobalScanner.findGlobal(holdingInstanceOf: StandInSingleton.self, in: [section.region])

        guard case .found(let object, let slotAddresses) = outcome else {
            Issue.record("Expected the slot to be found, got \(outcome)")
            return
        }
        #expect(object === singleton)
        #expect(slotAddresses == [section.slotAddress(17)])
    }

    @Test("an instance of another class is not mistaken for one")
    func ignoresAnInstanceOfAnotherClass() {
        let unrelated = UnrelatedStandIn(identifier: 1)
        let section = StandInSection(slotCount: 64)
        section.put(unrelated, inSlot: 17)

        let outcome = DockGlobalScanner.findGlobal(holdingInstanceOf: StandInSingleton.self, in: [section.region])

        #expect(isNotFound(outcome))
    }

    @Test("an all-zero section yields nothing")
    func findsNothingInAZeroedSection() {
        let section = StandInSection(slotCount: 256)

        let outcome = DockGlobalScanner.findGlobal(holdingInstanceOf: StandInSingleton.self, in: [section.region])

        #expect(isNotFound(outcome))
    }

    /// A slot left over from earlier use can hold anything at all; none of it may be dereferenced.
    ///
    /// These are the values the three sieves exist for: a small integer and a plausible-looking but
    /// unmapped address are not heap blocks, and an odd address is not even pointer-aligned. Reaching
    /// the end of this test is the assertion — a scanner that dereferenced any of them would crash the
    /// test process, which is what it would otherwise do to the Dock.
    @Test("values that are not objects are rejected without being dereferenced")
    func rejectsValuesThatAreNotObjects() {
        let section = StandInSection(slotCount: 8)
        section.putNonHeapValue(1, inSlot: 0)
        section.putNonHeapValue(0x10, inSlot: 1)
        section.putNonHeapValue(0x7FFF_FFFF_0000, inSlot: 2)
        section.putNonHeapValue(0x1_0000_0001, inSlot: 3)
        section.putNonHeapValue(UInt(UInt32.max), inSlot: 4)

        let outcome = DockGlobalScanner.findGlobal(holdingInstanceOf: StandInSingleton.self, in: [section.region])

        #expect(isNotFound(outcome))
    }

    @Test("a heap block smaller than an instance of the class is rejected")
    func rejectsAHeapBlockTooSmallToBeAnInstance() {
        let instanceSize = class_getInstanceSize(StandInSingleton.self)
        let tooSmall = malloc(1)!
        defer { free(tooSmall) }
        #expect(malloc_size(tooSmall) < instanceSize, "the premise of this test is that 1 byte rounds up to less than an instance")

        let section = StandInSection(slotCount: 8)
        section.putNonHeapValue(UInt(bitPattern: tooSmall), inSlot: 3)

        let outcome = DockGlobalScanner.findGlobal(holdingInstanceOf: StandInSingleton.self, in: [section.region])

        #expect(isNotFound(outcome))
    }

    /// A region whose own start is not pointer-aligned still has its pointers found.
    ///
    /// Walking a live process turns up `__DATA` sections aligned to less than a pointer. Stepping from
    /// an unaligned start would read one straddled slot after another and step past every real pointer
    /// in the section — silently, since a straddled value looks like any other value that is not an
    /// object. So the scan starts at the first aligned address inside the region instead.
    @Test("an object in a region that does not start pointer-aligned is still found")
    func findsAnAlignedObjectInAMisalignedRegion() throws {
        let singleton = StandInSingleton(identifier: 1)
        let slotSize = MemoryLayout<UnsafeRawPointer>.size
        let section = StandInSection(slotCount: 8)
        section.put(singleton, inSlot: 4)

        // The same bytes, described as starting one byte in — exactly what an under-aligned section
        // looks like, with the object's pointer still at an aligned address inside it.
        let misalignedRegion = PointerSlotRegion(
            baseAddress: section.region.baseAddress.advanced(by: 1),
            byteCount: section.region.byteCount - 1,
            name: "__DATA,__data"
        )
        #expect(UInt(bitPattern: misalignedRegion.baseAddress) % UInt(slotSize) != 0, "the premise is an unaligned start")

        let outcome = DockGlobalScanner.findGlobal(holdingInstanceOf: StandInSingleton.self, in: [misalignedRegion])

        guard case .found(let object, let slotAddresses) = outcome else {
            Issue.record("Expected the aligned slot to be found, got \(outcome)")
            return
        }
        #expect(object === singleton)
        #expect(slotAddresses == [section.slotAddress(4)])
    }

    // MARK: - Several hits

    @Test("several slots holding the same object are all reported, and the object is used")
    func acceptsSeveralSlotsHoldingTheSameObject() throws {
        let singleton = StandInSingleton(identifier: 1)
        let section = StandInSection(slotCount: 64)
        section.put(singleton, inSlot: 3)
        section.put(singleton, inSlot: 40)

        let outcome = DockGlobalScanner.findGlobal(holdingInstanceOf: StandInSingleton.self, in: [section.region])

        guard case .found(let object, let slotAddresses) = outcome else {
            Issue.record("Expected the object to be found, got \(outcome)")
            return
        }
        #expect(object === singleton)
        #expect(slotAddresses == [section.slotAddress(3), section.slotAddress(40)])
    }

    @Test("slots holding different instances are reported as ambiguous and none is used")
    func rejectsSlotsHoldingDifferentInstances() throws {
        let firstSingleton = StandInSingleton(identifier: 1)
        let secondSingleton = StandInSingleton(identifier: 2)
        let section = StandInSection(slotCount: 64)
        section.put(firstSingleton, inSlot: 3)
        section.put(secondSingleton, inSlot: 40)

        let outcome = DockGlobalScanner.findGlobal(holdingInstanceOf: StandInSingleton.self, in: [section.region])

        guard case .ambiguous(let slotAddresses) = outcome else {
            Issue.record("Expected the two instances to be ambiguous, got \(outcome)")
            return
        }
        #expect(slotAddresses == [section.slotAddress(3), section.slotAddress(40)])
    }

    // MARK: - Region order

    @Test("the first region that holds the object answers, and later regions are left alone")
    func stopsAtTheFirstRegionThatAnswers() throws {
        let singletonInFirstRegion = StandInSingleton(identifier: 1)
        let singletonInSecondRegion = StandInSingleton(identifier: 2)
        let firstSection = StandInSection(slotCount: 32, name: "__DATA,__common")
        let secondSection = StandInSection(slotCount: 32, name: "__DATA,__bss")
        firstSection.put(singletonInFirstRegion, inSlot: 5)
        secondSection.put(singletonInSecondRegion, inSlot: 5)

        let outcome = DockGlobalScanner.findGlobal(
            holdingInstanceOf: StandInSingleton.self,
            in: [firstSection.region, secondSection.region]
        )

        guard case .found(let object, _) = outcome else {
            Issue.record("Expected the first region to answer, got \(outcome)")
            return
        }
        #expect(object === singletonInFirstRegion)
    }

    @Test("a later region answers when the first holds nothing")
    func fallsThroughToALaterRegion() throws {
        let singleton = StandInSingleton(identifier: 1)
        let emptySection = StandInSection(slotCount: 32, name: "__DATA,__common")
        let populatedSection = StandInSection(slotCount: 32, name: "__DATA,__bss")
        populatedSection.put(singleton, inSlot: 5)

        let outcome = DockGlobalScanner.findGlobal(
            holdingInstanceOf: StandInSingleton.self,
            in: [emptySection.region, populatedSection.region]
        )

        guard case .found(let object, _) = outcome else {
            Issue.record("Expected the second region to answer, got \(outcome)")
            return
        }
        #expect(object === singleton)
    }

    @Test("no regions at all yields nothing rather than failing")
    func findsNothingWithoutRegions() {
        #expect(isNotFound(DockGlobalScanner.findGlobal(holdingInstanceOf: StandInSingleton.self, in: [])))
    }

    // MARK: - The real sections

    /// The host's own sections, which in a test process are the test runner's.
    ///
    /// A runner's executable can be small enough to have none of these sections, so this holds the
    /// lookup to shape rather than to presence: whatever comes back is in scan order, pointer-aligned
    /// and big enough to hold a slot.
    @Test("the host's data sections are described in scan order")
    func describesTheHostsSections() {
        expectRegionsAreWellFormed(DockGlobalScanner.mainExecutablePointerSlotRegions())
    }

    /// Scanning every loaded image's real sections for a class no global holds.
    ///
    /// This is the closest a test gets to the Dock's own `__common`: the data sections of a live process
    /// are full of leftover values — small integers, unmapped addresses, interior pointers, function
    /// addresses — and every one of them reaches the three sieves. Coming back empty *and* reaching the
    /// end of this test is the assertion; a scanner that dereferenced any of those would take the test
    /// process down, which is what it would otherwise do to the Dock.
    @Test("every loaded image's real sections are scanned safely and hold no instance of an absent class")
    func scanningEveryLoadedImageIsSafe() {
        var allRegions: [PointerSlotRegion] = []
        for imageIndex in 0..<_dyld_image_count() {
            let regions = DockGlobalScanner.pointerSlotRegions(ofImageAtIndex: imageIndex)
            expectRegionsAreWellFormed(regions)
            allRegions.append(contentsOf: regions)
        }

        #expect(allRegions.contains { $0.name == "__DATA,__common" }, "no image in this process has a __common section")
        #expect(isNotFound(DockGlobalScanner.findGlobal(holdingInstanceOf: UnrelatedStandIn.self, in: allRegions)))
    }

    /// Checks what the payload depends on about a region, whichever image it came from.
    ///
    /// Alignment is deliberately not among it: walking every loaded image turns up `__DATA` sections
    /// aligned to less than a pointer, which is the linker's business, not something a region has to
    /// promise. That the scan copes is what ``findsAnAlignedObjectInAMisalignedRegion()`` is for.
    private func expectRegionsAreWellFormed(_ regions: [PointerSlotRegion]) {
        let scanOrder = ["__DATA,__common", "__DATA,__bss", "__DATA,__data"]
        let names = regions.map(\.name)
        #expect(names == scanOrder.filter(names.contains), "regions are out of scan order: \(names)")
        for region in regions {
            #expect(region.byteCount >= MemoryLayout<UnsafeRawPointer>.size, "\(region.name) holds no slot")
        }
    }

    private func isNotFound(_ outcome: DockGlobalScanner.Outcome) -> Bool {
        if case .notFound = outcome { return true }
        return false
    }
}
