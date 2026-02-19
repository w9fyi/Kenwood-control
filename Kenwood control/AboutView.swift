import SwiftUI
import AppKit

struct AboutView: View {
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Kenwood control"
    }

    private var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    private var buildConfig: String {
        #if DEBUG
        return "Debug"
        #else
        return "Release"
        #endif
    }

    private var versionSummary: String {
        "\(appName) — \(versionString) — \(buildConfig)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(appName)
                .font(.title)
            Text(versionString)
            Text("Build: \(buildConfig)")
            Button("Copy Version Info") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(versionSummary, forType: .string)
            }
            Divider()
            Text("Accessible-first control app for the Kenwood TS-890S.")
                .font(.body)
        }
        .padding()
        .frame(minWidth: 360, minHeight: 180)
    }
}

// Note: SwiftUI Previews are disabled for command-line builds in this project to avoid
// preview macro/plugin issues in headless environments.
