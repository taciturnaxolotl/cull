import SwiftUI

struct SettingsView: View {
    @AppStorage("autoWriteXMP") private var autoWriteXMP: Bool = true
    @AppStorage("importRecursive") private var importRecursive: Bool = true

    var body: some View {
        Form {
            Section("Sidecars") {
                Toggle("Automatically write XMP sidecars", isOn: $autoWriteXMP)
                Text("Writes rating and flag changes to .xmp files alongside your photos for Lightroom/Bridge/darktable compatibility.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Import") {
                Toggle("Include subfolders by default", isOn: $importRecursive)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450)
        .fixedSize()
    }
}
