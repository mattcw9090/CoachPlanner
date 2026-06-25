import SwiftUI

/// App icon design for CoachPlanner.
///
/// How to install this as the actual app icon:
///   1. In Xcode, File → New → File from Template… → Asset Catalog. Name it `Assets`.
///   2. Inside the asset catalog, Editor → Add Asset → New iOS App Icon. Name it `AppIcon`.
///   3. Open this file's SwiftUI preview, right-click the canvas → Export Preview…,
///      save a 1024×1024 PNG, and drag it onto the AppIcon "1024 pt" slot.
///   4. Alternatively, render programmatically with `ImageRenderer(content: AppLogo())`
///      and save `renderer.uiImage` as a PNG.
struct AppLogo: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.27, green: 0.58, blue: 0.98),
                    Color(red: 0.10, green: 0.33, blue: 0.78)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: "figure.badminton")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
                .padding(180)
        }
        .frame(width: 1024, height: 1024)
    }
}

#Preview {
    AppLogo()
}
