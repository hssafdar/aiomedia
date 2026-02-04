import Foundation
import Combine
import SwiftUI

class SearchProviderManager: ObservableObject {
    static let shared = SearchProviderManager()
    
    // The master list of all available search engines
    @Published var allProviders: [SearchProvider] = [
        PirateBayProvider(),
        One337xProvider(),
        RuTorProvider(),
        DivxTotalProvider(),
        DodiProvider(),
        FitGirlProvider(),
        CloudTorrentsProvider(),
        MikanProvider(),
        DmhyProvider(),
        SoulseekProvider()
    ]
    
    func reorder(from source: IndexSet, to destination: Int) {
        allProviders.move(fromOffsets: source, toOffset: destination)
    }
}
