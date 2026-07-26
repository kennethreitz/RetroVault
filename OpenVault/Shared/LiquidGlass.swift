import SwiftUI

/// Applies OpenVault's Liquid Glass treatment to a custom surface.
///
/// Native SwiftUI navigation, sidebars, toolbars, menus, and search fields
/// receive Liquid Glass automatically on macOS 26. Use this modifier only for
/// custom controls or floating information that sits above app content.
extension View {
    func openVaultGlass<S: Shape>(
        tint: Color? = nil,
        interactive: Bool = false,
        in shape: S
    ) -> some View {
        glassEffect(
            .regular
                .tint(tint)
                .interactive(interactive),
            in: shape
        )
    }
}
