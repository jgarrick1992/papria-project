import SwiftUI

/// Reserved top-level feature boundary for account/reader controls that are
/// shared by the library and settings flows.  Keeping a concrete view here
/// mirrors the layered eeclass structure without coupling account controls to
/// a particular library screen.
struct ParentFeatureView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "book.closed")
            Text("Papria 阅读器")
        }
    }
}
