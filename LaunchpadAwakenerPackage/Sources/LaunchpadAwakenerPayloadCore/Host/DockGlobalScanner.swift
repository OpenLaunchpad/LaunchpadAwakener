import Foundation
import MachO
import ObjectiveC
import OSToolbox

/// A stretch of the host's memory that can be read one pointer slot at a time.
///
/// Regions are handed to the scanner rather than looked up inside it: finding a global is a pure
/// computation over memory, so the tests feed it a block they allocated themselves instead of having to
/// inject anything anywhere.
struct PointerSlotRegion {
    /// Where the region starts, aligned however the linker left it.
    ///
    /// Not necessarily aligned to a pointer: walking every loaded image of a live process turns up
    /// `__DATA` sections aligned to less than that. A pointer the host stored is always pointer-aligned,
    /// so scanning starts at the first aligned address at or after this one rather than here.
    let baseAddress: UnsafeRawPointer

    /// How many bytes the region covers. A tail too short to hold one more slot is ignored.
    let byteCount: Int

    /// What to call this region in the log, such as `__DATA,__common`.
    let name: String

    init(baseAddress: UnsafeRawPointer, byteCount: Int, name: String) {
        self.baseAddress = baseAddress
        self.byteCount = byteCount
        self.name = name
    }
}

/// Finds the host's singletons by what they hold, rather than by an address recorded per build.
///
/// The Dock keeps its singletons in file-scope `id` variables — the linker puts those in
/// `__DATA,__common` — and reads them directly everywhere. Nothing exported leads to them: `DockBar`
/// has no singleton accessor, the five event handlers do not hold it either, and the executable is
/// stripped, so neither a symbol lookup nor a property chain reaches it. What is left is to recognise
/// the global by what it holds: walk the host's writable data sections and accept the slot whose object
/// turns out to be an instance of the class being looked for.
///
/// That check *is* the definition of what is wanted, so unlike a recorded address it needs no per-build
/// table to be trusted against — which is why the payload no longer carries one.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockGlobalScanner")
enum DockGlobalScanner {
    /// What looking for one global turned up.
    ///
    /// The object comes back as `AnyObject` rather than `NSObject`: whether the caller can send it
    /// messages is the caller's business, and narrowing it here would quietly reject a class that is not
    /// an `NSObject` subclass instead of reporting it found.
    enum Outcome {
        /// One object was found, held by every slot listed.
        ///
        /// Several slots holding it is normal and harmless: the Dock reads the same singleton from more
        /// than one place, and they all point at the one object.
        case found(object: AnyObject, slotAddresses: [UnsafeRawPointer])

        /// No slot in any region holds an instance of the class.
        ///
        /// Either the object has not been built yet — the Dock creates its singletons during start-up,
        /// and the payload can be injected within 250 ms of that — or this Dock keeps it somewhere this
        /// scanner does not look.
        case notFound

        /// Different slots hold different instances, so which one the Dock itself reads is unknown.
        ///
        /// Never observed on macOS 26 or 27; both classes are process singletons. Reported rather than
        /// guessed at, the same way a hook batch is abandoned whole rather than installed in part.
        case ambiguous(slotAddresses: [UnsafeRawPointer])
    }

    // MARK: - Looking for a global

    /// Looks for a global holding an instance of `targetClass`, scanning `regions` in the order given
    /// and stopping at the first region that holds one.
    ///
    /// Scanning is cheap enough to be worth repeating rather than caching a failure: `__common` is
    /// around 1.6 KB on the Dock builds of macOS 26 and 27, so the region that normally answers is a
    /// couple of hundred slots.
    static func findGlobal(holdingInstanceOf targetClass: AnyClass, in regions: [PointerSlotRegion]) -> Outcome {
        let className = String(cString: class_getName(targetClass))
        let minimumInstanceSize = class_getInstanceSize(targetClass)
        for region in regions {
            let hits = hits(holdingInstanceOf: targetClass, minimumInstanceSize: minimumInstanceSize, in: region)
            guard let firstHit = hits.first else { continue }
            let slotAddresses = hits.map(\.slotAddress)
            guard hits.allSatisfy({ $0.object === firstHit.object }) else {
                let answer = "ambiguous in \(region.name), \(hits.count) slots"
                // `#log` reads its level where it expands, so the quiet repeat has to be its own call.
                if loggedAnswers.updateAnswer(answer, forName: className) != answer {
                    #log(
                        .error,
                        "\(region.name, privacy: .public) holds \(hits.count, privacy: .public) slots with different \(className, privacy: .public) instances; using none of them"
                    )
                } else {
                    #log(
                        .debug,
                        "\(region.name, privacy: .public) holds \(hits.count, privacy: .public) slots with different \(className, privacy: .public) instances; using none of them"
                    )
                }
                return .ambiguous(slotAddresses: slotAddresses)
            }
            let answer = "found in \(region.name), \(slotAddresses.count) slot(s)"
            if loggedAnswers.updateAnswer(answer, forName: className) != answer {
                #log(
                    .default,
                    "Found \(className, privacy: .public) in \(region.name, privacy: .public), \(slotAddresses.count, privacy: .public) slot(s)"
                )
            } else {
                #log(
                    .debug,
                    "Found \(className, privacy: .public) in \(region.name, privacy: .public), \(slotAddresses.count, privacy: .public) slot(s)"
                )
            }
            return .found(object: firstHit.object, slotAddresses: slotAddresses)
        }
        // Recorded, so that the find which follows an empty answer counts as news again. Not logged
        // here: the caller knows which class names it tried and reports that itself.
        loggedAnswers.updateAnswer("not found", forName: className)
        return .notFound
    }

    /// What was logged last time about each class, so that a control panel that refreshes every few
    /// seconds does not write the same line every time. See ``LoggedAnswers``.
    private static let loggedAnswers = LoggedAnswers()

    /// One slot that holds an instance of the class being looked for.
    private struct Hit {
        let slotAddress: UnsafeRawPointer
        let object: AnyObject
    }

    /// Every slot in `region` that holds an instance of `targetClass`, with what it holds.
    ///
    /// Address and object are collected together so nothing downstream has to re-read a slot and cope
    /// with it having been nil after all.
    private static func hits(
        holdingInstanceOf targetClass: AnyClass,
        minimumInstanceSize: Int,
        in region: PointerSlotRegion
    ) -> [Hit] {
        let slotSize = MemoryLayout<UnsafeRawPointer>.size
        var hits: [Hit] = []
        // A pointer the host stored is pointer-aligned, so start at the first aligned address in the
        // region. Sections aligned to less than a pointer do occur, and starting at an unaligned base
        // would step past every real pointer in them, one straddled slot at a time.
        let misalignment = Int(UInt(bitPattern: region.baseAddress) % UInt(slotSize))
        var slotOffset = misalignment == 0 ? 0 : slotSize - misalignment
        while slotOffset + slotSize <= region.byteCount {
            let slotAddress = region.baseAddress.advanced(by: slotOffset)
            slotOffset += slotSize
            guard
                let candidate = slotAddress.loadUnaligned(as: UnsafeRawPointer?.self),
                isInstance(candidate, of: targetClass, minimumInstanceSize: minimumInstanceSize)
            else { continue }
            // Proven to be an instance of targetClass just above, so handing it to ARC is safe here.
            hits.append(
                Hit(
                    slotAddress: slotAddress,
                    object: Unmanaged<AnyObject>.fromOpaque(candidate).takeUnretainedValue()
                )
            )
        }
        return hits
    }

    // MARK: - Deciding whether a candidate is an object at all

    /// Whether `candidate` is an instance of `targetClass`.
    ///
    /// Three sieves, none of which touches memory it has not already proven it may touch:
    ///
    /// 1. Non-null and aligned to a pointer. Every object allocation is at least pointer-aligned, so an
    ///    unaligned value cannot be one.
    /// 2. `malloc_size` recognises it, and the block is no smaller than an instance of `targetClass`.
    ///    `malloc_size` is safe to call on any wild pointer: it walks the registered zones asking each
    ///    one `zone->size(zone, pointer)`, and those compare address ranges rather than dereferencing
    ///    anything (libmalloc `malloc.c`, `malloc_size` and `_find_registered_zone`). A non-zero answer
    ///    also proves the pointer is the *start* of a block rather than somewhere inside one.
    /// 3. The class read off the front of that block equals `targetClass`. Only the two class pointers
    ///    are compared — the candidate is never messaged.
    private static func isInstance(
        _ candidate: UnsafeRawPointer,
        of targetClass: AnyClass,
        minimumInstanceSize: Int
    ) -> Bool {
        guard UInt(bitPattern: candidate) % UInt(MemoryLayout<UnsafeRawPointer>.alignment) == 0 else { return false }
        guard malloc_size(candidate) >= minimumInstanceSize else { return false }
        return classOfRawPointer?(candidate) === targetClass
    }

    /// `object_getClass`, typed to take a raw pointer.
    ///
    /// Swift imports `object_getClass` as taking `Any?`, and reaching it through `Unmanaged` would hand
    /// ARC a reference to a candidate that has not been proven to be an object yet — `takeUnretainedValue`
    /// returns an owned value, so the compiler is free to retain it, and retaining a non-object reads a
    /// garbage isa. Calling the C entry point through a function pointer keeps every candidate a plain
    /// address until its class has been compared.
    ///
    /// `AnyClass` is a metatype and so outside ARC; returning it inserts no retain. Nil only if libobjc
    /// somehow lacks the symbol, in which case nothing is ever found rather than wrongly found.
    ///
    /// Looked up once. `RTLD_DEFAULT` searches every image in the process and `dlfcn.h` calls that
    /// expensive, which is why this is a `static let` rather than something each candidate pays for.
    private static let classOfRawPointer: (@convention(c) (UnsafeRawPointer?) -> AnyClass?)? = {
        // RTLD_DEFAULT: a pointer constant that no Swift overlay re-exports, so it is spelled out.
        let defaultSearchOrder = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(defaultSearchOrder, "object_getClass") else {
            #log(.error, "object_getClass is not available; no global can be found")
            return nil
        }
        return unsafeBitCast(symbol, to: (@convention(c) (UnsafeRawPointer?) -> AnyClass?).self)
    }()

    // MARK: - The host's own data sections

    /// The sections of the host worth scanning, in the order they are scanned.
    ///
    /// The host is the main executable — the process the payload was injected into.
    static func mainExecutablePointerSlotRegions() -> [PointerSlotRegion] {
        // dyld always lists the main executable first.
        pointerSlotRegions(ofImageAtIndex: 0)
    }

    /// The sections worth scanning in one image dyld has mapped, in the order they are scanned.
    ///
    /// `__common` comes first because that is where both Dock globals live on every build of macOS 26
    /// and 27 that was checked — 1.6 KB, a couple of hundred slots. `__bss` and `__data` follow only as
    /// a fallback, in case a future Dock is built so that the globals land in one of them. All three are
    /// inside `__DATA`, which dyld maps read-write. An image without one of them simply contributes
    /// fewer regions.
    ///
    /// The index is a parameter so the tests can walk every image in their own process: a test runner's
    /// own executable is small enough to have none of these sections, while the libraries loaded
    /// alongside it have all three, full of the leftover values the three sieves exist for.
    static func pointerSlotRegions(ofImageAtIndex imageIndex: UInt32) -> [PointerSlotRegion] {
        guard let header = _dyld_get_image_header(imageIndex) else {
            #log(.error, "Could not reach the Mach-O header of image \(imageIndex, privacy: .public)")
            return []
        }
        return ["__common", "__bss", "__data"].compactMap { sectionName in
            pointerSlotRegion(inSegmentNamed: "__DATA", sectionNamed: sectionName, of: header)
        }
    }

    /// One section of an image dyld has already mapped, as a region to scan; nil when the image has no
    /// such section, or it is empty.
    ///
    /// `getsectiondata` returns where the section actually is in memory, working the slide out from the
    /// header it is given, so no address here can go stale with a new build of the host. Its deprecated
    /// sibling `getsectbynamefromheader_64` would hand back the recorded unslid address instead, leaving
    /// the slide to be added by hand.
    private static func pointerSlotRegion(
        inSegmentNamed segmentName: String,
        sectionNamed sectionName: String,
        of header: UnsafePointer<mach_header>
    ) -> PointerSlotRegion? {
        let header64 = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
        var byteCount: UInt = 0
        guard
            let sectionStart = getsectiondata(header64, segmentName, sectionName, &byteCount),
            byteCount >= UInt(MemoryLayout<UnsafeRawPointer>.size)
        else { return nil }
        return PointerSlotRegion(
            baseAddress: UnsafeRawPointer(sectionStart),
            byteCount: Int(byteCount),
            name: "\(segmentName),\(sectionName)"
        )
    }
}
