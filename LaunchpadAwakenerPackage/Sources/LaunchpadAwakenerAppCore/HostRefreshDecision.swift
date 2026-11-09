import Foundation

/// What a state refresh should do about one host it knows something about.
///
/// A table rather than two `if`s because collapsing its two failure rows into one caused an
/// injection loop: a payload that would not answer was treated as a host that had gone away, the
/// host was struck off the injected list, the next discovery pass saw a target that had never been
/// injected, and injected it again — every few seconds, indefinitely.
///
/// The distinction that has to survive: **a payload is a mapped image that cannot be unloaded**, so
/// once an injection has succeeded, "this host is injected" stays true for the life of the host
/// whether or not the side channel used to ask it about itself still works. Losing the channel
/// costs the interface some detail. It does not undo the injection, and re-injecting would not
/// restore it — the second `dlopen` of an image already in the process does nothing at all.
enum HostRefreshDecision: Sendable, Equatable {
    /// Alive and answering. Nothing to do.
    case keepAsIs

    /// Alive, not answering yet, but freshly injected — its payload may still be mid-handshake.
    /// Change nothing and ask again next time.
    case waitForHandshake

    /// Alive but its payload will not answer. Drop the channel and the stale report, and *keep the
    /// host on record as injected*.
    case dropChannelKeepingInjectionOnRecord

    /// The host process is gone. Drop everything, injection record included.
    case forgetEntirely

    /// The whole decision, in one place.
    ///
    /// - Parameters:
    ///   - hostIsAlive: whether the host process still exists.
    ///   - payloadAnswered: whether this pass got a status back.
    ///   - payloadHasEverAnswered: whether any pass ever has. A payload that has answered before
    ///     and stopped is genuinely broken; one that never has may just not be ready.
    ///   - isWithinHandshakeGracePeriod: whether the channel is new enough that a payload could
    ///     still be completing its side of the handshake.
    static func decide(
        hostIsAlive: Bool,
        payloadAnswered: Bool,
        payloadHasEverAnswered: Bool,
        isWithinHandshakeGracePeriod: Bool
    ) -> HostRefreshDecision {
        guard hostIsAlive else { return .forgetEntirely }
        if payloadAnswered { return .keepAsIs }
        // Giving up here would close this app's listener — the endpoint the payload is in the
        // middle of connecting to — turning "not ready yet" into "never going to work".
        if !payloadHasEverAnswered, isWithinHandshakeGracePeriod { return .waitForHandshake }
        return .dropChannelKeepingInjectionOnRecord
    }
}

/// Picks the targets an automatic pass should inject into.
///
/// The other half of the loop above: whatever this returns gets injected, so anything already
/// injected has to be excluded here as firmly as it is recorded there.
enum InjectionSelection {
    static func processIdentifiersNeedingInjection(
        running runningProcessIdentifiers: [pid_t],
        alreadyInjected: Set<pid_t>,
        beingInjected: Set<pid_t>
    ) -> [pid_t] {
        runningProcessIdentifiers.filter { processIdentifier in
            !alreadyInjected.contains(processIdentifier) && !beingInjected.contains(processIdentifier)
        }
    }
}
