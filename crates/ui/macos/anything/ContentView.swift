import SwiftUI
import AppKit
import GeneratedStore

struct ContentView: View {
    @StateObject private var configService = StoreConfigService()

    var body: some View {
        ZStack {
            GeometryReader { geo in
                radialOrb(
                    color: Color(red: 0.46, green: 0.78, blue: 1.0).opacity(0.20),
                    size: 420, blur: 48
                )
                .offset(x: -geo.size.width * 0.15, y: -geo.size.height * 0.25)

                radialOrb(
                    color: Color(red: 0.36, green: 0.62, blue: 1.0).opacity(0.18),
                    size: 360, blur: 44
                )
                .offset(x: geo.size.width * 0.55, y: geo.size.height * 0.45)

                radialOrb(
                    color: Color(red: 0.92, green: 0.94, blue: 1.0).opacity(0.18),
                    size: 300, blur: 42
                )
                .offset(x: geo.size.width * 0.35, y: geo.size.height * 0.35)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            HStack(alignment: .top, spacing: 20) {
                SidebarView()
                    .frame(maxHeight: .infinity, alignment: .top)

                SearchPanelView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .environmentObject(configService)
            .padding(.leading, 20)
            .padding(.trailing, 24)
            .padding(.vertical, 22)
        }
        .ignoresSafeArea()
        .frame(minWidth: 820, minHeight: 540)
        .background(WindowConfigurator())
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.06, blue: 0.14),
                    Color(red: 0.05, green: 0.09, blue: 0.18),
                    Color(red: 0.02, green: 0.04, blue: 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func radialOrb(color: Color, size: CGFloat, blur: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color, .clear], center: .center,
                                 startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
            .blur(radius: blur)
    }
}

// MARK: - Window Configurator

private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.hasShadow = true
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

#Preview {
    ContentView()
}
