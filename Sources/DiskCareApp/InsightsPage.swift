import DiskCareCore
import SwiftUI

/// Placeholder until the Insights page lands.
struct InsightsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        Page {
            Card { GrowthView(model: model.growth, maxRows: 25) }
            ExplainCard(model: model)
        }
    }
}
