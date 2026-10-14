import Foundation
import ApleTimingCore

public struct LayerTimingSnapshot: Sendable {
    public let layerID: String
    public let revision: String
    public let title: String
    public let document: TimingDocument
    /// Valid source presentation timestamps, inclusive; nil for non-media properties.
    public let sourceRange: ClosedRange<Double>?

    public init(layerID: String, revision: String, title: String, document: TimingDocument,
                sourceRange: ClosedRange<Double>? = nil) throws {
        guard !layerID.isEmpty, !revision.isEmpty else { throw TimingError.invalidDocument }
        try document.validate()
        if let range = sourceRange {
            guard range.lowerBound.isFinite, range.upperBound.isFinite else { throw TimingError.invalidNumber }
        }
        self.layerID = layerID; self.revision = revision; self.title = title
        self.document = document; self.sourceRange = sourceRange
    }
}

/// Implement against the verified current Aple Motion project model, never private ABI guesses.
/// An implementation must share this exact timing map between preview and export.
@MainActor public protocol TimingHostAdapter: AnyObject {
    func snapshot() throws -> LayerTimingSnapshot
    /// Transient preview only. Must not persist changes or push original-editor undo entries.
    func preview(_ document: TimingDocument) throws
    /// Atomically validate the revision, update the layer, invalidate render caches, persist,
    /// and push exactly one original-editor undo entry. Return only after durable success.
    /// Throw on stale revisions or unsupported timing modes; never silently ignore a control.
    func commit(_ document: TimingDocument, expectedRevision: String) async throws -> LayerTimingSnapshot
    /// Restore the pre-edit preview without overwriting concurrent edits made elsewhere.
    func cancelPreview()
}
