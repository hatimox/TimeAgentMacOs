import SwiftUI
import CryptoKit

/// Gravatar avatar for the signed-in user, falling back to a tinted initials
/// circle while loading or when no email / image is available.
struct AvatarView: View {
    let name: String
    let email: String
    var size: CGFloat = 30

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(tint.gradient)
                Text(initials).font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        .task(id: email) { await load() }
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap { $0.first }.map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }

    /// Stable per-name tint so the fallback circle isn't a flat gray.
    private var tint: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green]
        let h = abs(name.hashValue)
        return palette[h % palette.count]
    }

    private func load() async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { image = nil; return }
        let digest = Insecure.MD5.hash(data: Data(trimmed.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let px = Int(size * 3)   // retina-friendly; d=404 = no fallback image
        guard let url = URL(string: "https://www.gravatar.com/avatar/\(digest)?s=\(px)&d=404") else { return }
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let img = NSImage(data: data) else { return }
        image = img
    }
}
