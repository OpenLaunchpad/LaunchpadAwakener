import AppKitPlus
import UIFoundation

/// Stops the build when UIFoundation was compiled without its `AppKitPlus` trait.
///
/// Without the trait `LayerBackedView` inherits `NSView` instead of AppKitPlus's `NSLayerBackedView`,
/// and every Xibless view silently loses AppKitPlus's layer-backed behaviour. Nothing else would fail
/// to compile: the build would succeed with the wrong base class. Never called; compiling it is the check.
@MainActor
private func requireUIFoundationBuiltWithAppKitPlusTrait() {
    let _: NSLayerBackedView.Type = LayerBackedView.self
}
