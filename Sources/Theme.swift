import SwiftUI

enum Theme {
    static let bgTop = Color(red: 0.06, green: 0.07, blue: 0.12)
    static let bgBottom = Color(red: 0.02, green: 0.02, blue: 0.04)
    static let card = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.08)
    static let accent = Color(red: 0.38, green: 0.58, blue: 1.0)
    static let accent2 = Color(red: 0.64, green: 0.42, blue: 1.0)
    static let folderTop = Color(red: 1.0, green: 0.80, blue: 0.28)
    static let folderBottom = Color(red: 1.0, green: 0.55, blue: 0.20)

    static var gradient: LinearGradient {
        LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var folderGradient: LinearGradient {
        LinearGradient(colors: [folderTop, folderBottom], startPoint: .top, endPoint: .bottom)
    }
}

struct AppBackground: View {
    var body: some View {
        LinearGradient(colors: [Theme.bgTop, Theme.bgBottom], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

struct EmptyState: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 54))
                .foregroundStyle(Theme.gradient)
            Text(text)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 110)
        .padding(.horizontal, 30)
    }
}

struct SectionTitle: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.headline)
            Text("\(count)")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.card))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }
}

struct Chip: View {
    let title: String
    let icon: String?
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.caption) }
            Text(title).font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .foregroundColor(selected ? .white : .secondary)
        .background(
            Capsule().fill(selected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.card))
        )
    }
}

struct LockButton: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            app.lock()
        } label: {
            Image(systemName: "lock.fill")
        }
    }
}

struct BusyOverlay: View {
    let text: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().tint(.white).scaleEffect(1.3)
                Text(text).font(.callout).foregroundColor(.white)
            }
            .padding(26)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.14)))
        }
    }
}
