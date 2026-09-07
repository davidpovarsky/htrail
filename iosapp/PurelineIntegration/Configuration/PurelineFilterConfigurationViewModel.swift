import Combine
import Foundation
import ImageFilterCore

@MainActor
final class PurelineFilterConfigurationViewModel: ObservableObject {
    @Published private(set) var snapshot: PurelineFilterConfigurationSnapshot?
    @Published private(set) var acknowledgement: PurelineFilterRevision?
    @Published var errorMessage: String?
    @Published var exportDocument: PurelineConfigurationDocument?

    private let store = PurelineFilterConfigurationStore.shared
    private var refreshTask: Task<Void, Never>?

    func start() {
        refresh()
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                refresh()
            }
        }
    }

    func stop() { refreshTask?.cancel(); refreshTask = nil }

    func refresh() {
        do {
            snapshot = try store.loadActive()
            acknowledgement = store.loadAcknowledgement()
            errorMessage = nil
        } catch { errorMessage = String(describing: error) }
    }

    func importConfiguration(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            snapshot = try store.install(data: Data(contentsOf: url), importedFilename: url.lastPathComponent)
            errorMessage = nil
        } catch { errorMessage = String(describing: error) }
    }

    func restoreDefault() {
        do { snapshot = try store.restoreDefault(); errorMessage = nil }
        catch { errorMessage = String(describing: error) }
    }

    func prepareExport() {
        do { exportDocument = PurelineConfigurationDocument(data: try store.exportActive()); errorMessage = nil }
        catch { errorMessage = String(describing: error) }
    }
}
