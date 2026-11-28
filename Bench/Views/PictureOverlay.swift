import SwiftUI
import BenchKit

/// Lets a picture in any chat open over the whole window, above the
/// sidebar, tabs and terminals, instead of in a small sheet.
private struct PictureOverlay: ViewModifier {
    @State private var shown: ShownPicture?
    @State private var closings = 0

    func body(content: Content) -> some View {
        content
            .environment(\.showPicture) { picture in shown = picture }
            .environment(\.pictureClosings, closings)
            .overlay {
                if let shown {
                    PictureViewer(shown) {
                        self.shown = nil
                        closings += 1
                    }
                        .id(shown.id)
                        .ignoresSafeArea()
                }
            }
    }
}

extension EnvironmentValues {
    /// Counts the pictures closed over this window, so the message box
    /// behind can take the cursor back when one closes.
    @Entry var pictureClosings = 0
}

extension View {
    func showsPicturesOverWindow() -> some View { modifier(PictureOverlay()) }
}
