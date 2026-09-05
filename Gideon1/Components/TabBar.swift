import SwiftUI

/// Floating row of 5 tab icons (no background bar). Active icon sits in a white circle with a soft shadow.
struct TabBar: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        selection = tab
                    }
                } label: {
                    TabIcon(tab: tab, isActive: selection == tab)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .accessibilityLabel(tab.accessibilityLabel)
            }
        }
        .padding(.horizontal, 28)
        .frame(height: 58)
    }
}

private struct TabIcon: View {
    let tab: AppTab
    let isActive: Bool

    var body: some View {
        ZStack {
            if isActive {
                Circle()
                    .fill(Color.white)
                    .frame(width: 46, height: 46)
                    .shadow(color: Color.black.opacity(0.07), radius: 10, x: 0, y: 3)
            }
            iconView
                .foregroundStyle(isActive ? AppTheme.textPrimary : AppTheme.textTertiary)
        }
        .frame(width: 46, height: 46)
    }

    @ViewBuilder
    private var iconView: some View {
        switch tab {
        case .agent:
            BotTabMark(size: 20, color: isActive ? AppTheme.textPrimary : AppTheme.textTertiary)
        case .messages:
            MessageTabMark(size: 17, color: isActive ? AppTheme.textPrimary : AppTheme.textTertiary)
        case .activity:
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 16, weight: .regular))
                .symbolRenderingMode(.monochrome)
        case .projects:
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 16, weight: .regular))
                .symbolRenderingMode(.monochrome)
        case .connections:
            ChipTabMark(size: 20, color: isActive ? AppTheme.textPrimary : AppTheme.textTertiary)
        }
    }
}

/// Computer-chip mark with the center square left empty.
private struct ChipTabMark: View {
    var size: CGFloat = 22
    var color: Color

    var body: some View {
        let lineWidth: CGFloat = size * 0.078
        let spacing: CGFloat = size * 0.19
        let halfLength: CGFloat = size * 0.34
        let mid: CGFloat = size / 2

        Canvas { ctx, _ in
            let stroke = GraphicsContext.Shading.color(color)
            let style = StrokeStyle(lineWidth: lineWidth, lineCap: .square)

            let left = mid - halfLength
            let right = mid + halfLength
            let top = mid - halfLength
            let bottom = mid + halfLength

            for offset in [-spacing, spacing] {
                var horizontal = Path()
                horizontal.move(to: CGPoint(x: left, y: mid + offset))
                horizontal.addLine(to: CGPoint(x: right, y: mid + offset))
                ctx.stroke(horizontal, with: stroke, style: style)

                var vertical = Path()
                vertical.move(to: CGPoint(x: mid + offset, y: top))
                vertical.addLine(to: CGPoint(x: mid + offset, y: bottom))
                ctx.stroke(vertical, with: stroke, style: style)
            }

            var centerSegments = Path()
            centerSegments.move(to: CGPoint(x: mid, y: top))
            centerSegments.addLine(to: CGPoint(x: mid, y: mid - spacing))
            centerSegments.move(to: CGPoint(x: mid, y: mid + spacing))
            centerSegments.addLine(to: CGPoint(x: mid, y: bottom))
            centerSegments.move(to: CGPoint(x: left, y: mid))
            centerSegments.addLine(to: CGPoint(x: mid - spacing, y: mid))
            centerSegments.move(to: CGPoint(x: mid + spacing, y: mid))
            centerSegments.addLine(to: CGPoint(x: right, y: mid))
            ctx.stroke(centerSegments, with: stroke, style: style)
        }
        .frame(width: size, height: size)
    }
}

/// Speech bubble with tail integrated into the bottom-left corner — single connected outline.
private struct MessageTabMark: View {
    var size: CGFloat = 22
    var color: Color

    var body: some View {
        MessageBubbleShape()
            .stroke(color, style: StrokeStyle(lineWidth: size * 0.088, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

private struct MessageBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.width * 0.22
        let tailH = rect.height * 0.20
        let bodyH = rect.height - tailH
        let tailBaseEnd = rect.minX + rect.width * 0.30

        var p = Path()
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
                 radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + bodyH - r))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + bodyH - r),
                 radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: tailBaseEnd, y: rect.minY + bodyH))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + bodyH + tailH))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r),
                 radius: r, startAngle: .degrees(180), endAngle: .degrees(-90), clockwise: false)
        p.closeSubpath()
        return p
    }
}
