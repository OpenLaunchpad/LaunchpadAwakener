//
//  main.m
//  LaunchpadAwakenerPayload
//
//  The payload's two entry points. Both call the same Swift initialiser; which one runs depends on
//  how the daemon injected this image.
//

#include <stdlib.h>

/// Implemented in Swift as `LaunchpadAwakener_payload_initialize` (see `LaunchpadAwakenerPayloadCore/PayloadEntry.swift`).
/// Declared here as plain C because `@_cdecl` is what makes the unmangled symbol available.
extern void LaunchpadAwakener_payload_initialize(void);

// -----------------------------------------------------------------------------
// Entry 1 — dlopen injection.
// -----------------------------------------------------------------------------
//
// dyld runs constructors for every image it loads, so injecting by `dlopen` needs nothing beyond
// this function existing.
//
// Note that this also fires when the *injector* dlopens the payload, which the remap path does to
// resolve the entry symbol below. `PayloadEntry.start()` detects that case and returns without
// doing anything, so there is no guard needed here.
// -----------------------------------------------------------------------------

__attribute__((constructor, used))
static void LaunchpadAwakener_payload_constructor(void) {
    LaunchpadAwakener_payload_initialize();
}

// -----------------------------------------------------------------------------
// Entry 2 — mach_vm_remap injection.
// -----------------------------------------------------------------------------
//
// Needed for targets whose sandbox profile denies `file-map-executable`, which makes dlopen
// impossible. The injector maps this image into the target manually and starts a thread here.
//
// By the time this runs, MachInjector's loader has already done everything dyld would have done
// except the constructor pass:
//   * applied the image's chained fixups against the target's pointer-authentication keys, and
//   * replayed dyld's runtime notifications on the target's behalf, so the Objective-C runtime has
//     registered this image's classes, categories, protocols and selectors, and the Swift runtime
//     has its type metadata and protocol conformances.
//
// The constructor pass is the one thing that never happens, which is exactly why this function
// exists: it hand-calls what the constructor above would have called.
//
// `argument` points at the injector's payload-configuration record in the target's address space.
// The loader has already consumed every field, so nothing here needs it — but it is accepted and
// ignored to keep the signature a valid `void *(*)(void *)` for pthread.
//
// The symbol name must match `InjectionServiceIdentity.payloadRemapEntrySymbol`.
// -----------------------------------------------------------------------------

__attribute__((visibility("default"), used))
void *LaunchpadAwakener_payload_remap_entry(void *argument) {
    (void)argument;
    LaunchpadAwakener_payload_initialize();
    return NULL;
}
