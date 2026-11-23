/// Whether to restart the Dock once at launch, because an update left it running the old payload.
///
/// The payload loaded in the Dock cannot be swapped while the Dock runs (see `hasStalePayload`), so a new
/// build of this app works against an old payload until the Dock restarts. The user asked Sparkle to install
/// the update, so the restart that finishes it happens without asking again; only the first launch of the
/// new build does it, and only when the Dock really runs an older payload.
public enum DockRestartAfterUpdate {
    public static func isNeeded(isNewBuild: Bool, isInjectionAllowed: Bool, hasStalePayload: Bool) -> Bool {
        isNewBuild && isInjectionAllowed && hasStalePayload
    }
}
