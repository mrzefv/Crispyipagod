import Foundation

enum BundledKeys {
    static let cesiumIon = ""
    static let googleMapTiles = ""
}

enum RemoteKeys {
    @MainActor
    static func apply(to state: AppState) async {
        _ = state
        // Optional fallback for CI/builds with no secret store.
        // If you later add a secret source, populate state.ionToken / state.googleMapsKey here.
    }
}
