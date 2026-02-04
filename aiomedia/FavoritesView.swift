import SwiftUI

struct FavoritesView: View {
    @ObservedObject private var viewModel = SearchViewModel.shared
    
    var body: some View {
        NavigationView {
            List {
                if viewModel.favorites.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "star.slash")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        Text("No favorites yet")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(viewModel.favorites) { item in
                        NavigationLink(destination: DetailView(item: item)) {
                            DetailedResultRow(item: item) // Now available via Components.swift
                        }
                    }
                    .onDelete(perform: deleteFavorite)
                }
            }
            .navigationTitle("Favorites")
        }
    }
    
    func deleteFavorite(at offsets: IndexSet) {
        viewModel.favorites.remove(atOffsets: offsets)
        // Manual save trigger since we modified the array directly
        if let data = try? JSONEncoder().encode(viewModel.favorites) {
            UserDefaults.standard.set(data, forKey: "SavedFavorites")
        }
    }
}
