import SwiftUI

struct MessagesView: View {
    @State private var message: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle.
            Capsule()
                .fill(AppTheme.textMuted)
                .frame(width: 42, height: 4)
                .padding(.top, 4)

            // Top right plus.
            HStack {
                Spacer()
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)

            Spacer()

            // Model label beneath the orb.
            Eyebrow(text: "Qwen2.5-3B-Instruct", size: 13, color: AppTheme.textSecondary)
                .padding(.bottom, 16)

            // Composer.
            composer
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Message Gideon…", text: $message)
                .font(.system(size: 15))
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.leading, 18)

            Button {
                // send
            } label: {
                ZStack {
                    Circle()
                        .fill(AppTheme.darkBlock)
                        .frame(width: 38, height: 38)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
        }
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 4)
        )
    }
}

#Preview { RootView() }
