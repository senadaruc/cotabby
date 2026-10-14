import SwiftUI

/// MLX engine sections of the unified engine pane. Task 13 of the MLX plan replaces this
/// interim body with install, model and advanced controls once the MLX services exist.
extension EngineAndModelPaneView {
    @ViewBuilder
    var mlxSections: some View {
        Section("MLX") {
            Text("MLX setup is not available in this build yet.")
                .foregroundStyle(.secondary)
        }
    }
}
