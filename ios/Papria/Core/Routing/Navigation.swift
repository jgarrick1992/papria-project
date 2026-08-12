import Foundation

enum PapriaRoute: Hashable {
    case library
    case reader(localID: String)
    case transfer
    case settings
}
