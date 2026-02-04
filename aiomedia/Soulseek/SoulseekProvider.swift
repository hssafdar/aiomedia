import Foundation
import Combine

class SoulseekProvider: SearchProvider {
    let name = "Soulseek"
    let baseURL = "server.slsknet.org"
    
    private var cancellables = Set<AnyCancellable>()
    private let resultsPublisher = PassthroughSubject<[SearchResult], Never>()
    
    // The ViewModel calls this
    func search(query: String) async throws -> [SearchResult] {
        let client = SoulseekClient.shared
        
        // 1. Setup Listener for Results
        // We clear previous listeners to avoid duplicates
        cancellables.removeAll()
        
        client.searchResultsSubject
            .sink { [weak self] results in
                self?.resultsPublisher.send(results)
            }
            .store(in: &cancellables)
        
        // 2. Trigger Search
        if client.isLoggedIn {
            client.search(query: query)
        }
        
        // 3. Return an Empty List immediately
        // Results come in via the publisher (resultStream) later
        return []
    }
    
    // Helper for ViewModel to attach to
    var resultStream: AnyPublisher<[SearchResult], Never> {
        // FIX: Use 'SoulseekClient.shared' directly here
        return SoulseekClient.shared.searchResultsSubject.eraseToAnyPublisher()
    }
}
