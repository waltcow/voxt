import SwiftUI

struct AppearanceSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Soon")
                .font(.headline)
            Text("Appearance settings are coming later.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }
}
