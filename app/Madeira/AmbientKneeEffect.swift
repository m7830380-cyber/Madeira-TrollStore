import SwiftUI

/// The dark-mode glow knee uses a SwiftUI shader available from iOS 17.
/// On iOS 16 the underlying artwork glow remains visible without the knee.
struct AmbientKneeEffect: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.colorEffect(ShaderLibrary.ambientKnee(.float(0.3)), isEnabled: enabled)
        } else {
            content
        }
    }
}
