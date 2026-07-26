enum ControllerFaceButtonLayout: Equatable, Sendable {
    case standard
    case nintendo

    static func resolve(
        vendorName: String?,
        productCategory: String
    ) -> Self {
        let identity = [vendorName, productCategory]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        return identity.contains("nintendo") || identity.contains("switch")
            ? .nintendo
            : .standard
    }
}
