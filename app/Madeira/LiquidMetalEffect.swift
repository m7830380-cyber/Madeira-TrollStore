import SwiftUI

/// Animated liquid-metal artwork is a shader feature introduced in iOS 17.
/// Preserve the animated shader on newer systems and render a plain fill on iOS 16.
struct LiquidMetalEffect: ViewModifier {
    let size: CGSize
    let time: Float
    let displayScale: Float
    let light: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.colorEffect(ShaderLibrary.liquidMetal(.float2(size), .float(time),
                                                           .float(displayScale), .float(light ? 1 : 0)))
        } else {
            content.foregroundStyle(light ? Color.white : Color.gray)
        }
    }
}
