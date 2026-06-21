import SwiftUI

/// Circular avatar that loads a profile photo by its object key, falling back to
/// the first letter of the name.
struct AvatarView: View {
    @EnvironmentObject var app: AppState
    let photoKey: String?
    let name: String
    var size: CGFloat = 44
    var isGroup: Bool = false

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(Color.accentColor.opacity(0.2))
                if isGroup {
                    Image(systemName: "person.2.fill").foregroundStyle(.secondary)
                } else {
                    Text(name.prefix(1).uppercased()).font(.headline)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: photoKey) {
            guard let photoKey, !photoKey.isEmpty else { return }
            image = await app.avatarImage(forKey: photoKey)
        }
    }
}
