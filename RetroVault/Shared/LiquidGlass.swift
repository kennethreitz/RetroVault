import SwiftUI

/// Applies RetroVault's Liquid Glass treatment to a custom surface.
///
/// Native SwiftUI navigation, sidebars, toolbars, menus, and search fields
/// pick up the system material for the running OS. Use this modifier only for
/// custom controls or floating information that sits above app content.
///
/// macOS 26 draws the surface with `glassEffect`. macOS 15 fills the same
/// shape with `.regularMaterial` and washes the caller's tint over that
/// material, behind the label. `interactive` enables the glass press
/// response on macOS 26; the material fallback has no separate press effect.
extension View {
    func openVaultGlass<S: Shape>(
        tint: Color? = nil,
        interactive: Bool = false,
        in shape: S
    ) -> some View {
        modifier(
            OpenVaultGlassModifier(
                tint: tint,
                interactive: interactive,
                shape: shape
            )
        )
    }

    /// Primary action. Liquid Glass on macOS 26, bordered prominent on macOS 15.
    @ViewBuilder
    func openVaultProminentButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

private struct OpenVaultGlassModifier<S: Shape>: ViewModifier {
    var tint: Color?
    var interactive: Bool
    var shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(
                .regular
                    .tint(tint)
                    .interactive(interactive),
                in: shape
            )
        } else {
            content.background {
                shape
                    .fill(.regularMaterial)
                    .overlay {
                        if let tint {
                            shape.fill(tint)
                        }
                    }
                    .allowsHitTesting(false)
            }
        }
    }
}
