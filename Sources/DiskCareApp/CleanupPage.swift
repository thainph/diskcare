import DiskCareCore
import SwiftUI

/// Placeholder until the unified Clean up page lands.
struct CleanupPage: View {
    @Bindable var model: AppModel

    var body: some View {
        Page { ProjectsView(model: model) }
    }
}

struct ReviewSheet: View {
    @Bindable var model: AppModel

    var body: some View {
        Text("Review")
    }
}
