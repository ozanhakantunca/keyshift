import AppKit
import SwiftUI

struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Group {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable().frame(width: 96, height: 96)
                } else {
                    Image(systemName: "keyboard").font(.system(size: 64))
                }
            }
            Text(verbatim: "Keyshift").font(.largeTitle.weight(.semibold))
            Text("Version \(version)").foregroundStyle(.secondary)
            Text("A free, open-source keyboard remapper for macOS — your Windows and Linux habits, on a Mac.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text("Licensed under the GNU General Public License v3.0. No telemetry, no paid tier.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Link(destination: URL(string: "https://github.com/ozanhakantunca/keyshift")!) {
                Label(String(localized: "Keyshift on GitHub"), systemImage: "arrow.up.right.square")
            }
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
