import Foundation

/// Why an edit to the timeline was refused.
public enum DocumentEditError: Error, Hashable, Sendable, CustomStringConvertible {
    case featureNotFound(UUID)
    /// Moving the feature would place it before a feature it uses (`dependency`)
    /// or after a feature that uses it (`dependent`).
    case dependencyViolation(feature: UUID, other: UUID)

    public var description: String {
        switch self {
        case .featureNotFound: "The feature no longer exists."
        case .dependencyViolation: "A feature can't be moved before the features it uses or after the ones that use it."
        }
    }
}

/// Result of deleting a feature.
public struct FeatureDeletion: Hashable, Sendable {
    /// Ids actually removed (the feature, plus its dependents when cascading).
    public var removed: [UUID]
    /// Remaining features that referenced a removed feature (they will fail to recompute).
    public var brokenDependents: [UUID]
}

/// Value-type mutations used by the app; each is a single undoable step
/// (the app snapshots the whole `Document` for undo).
extension Document {
    /// Ids of the features `id` directly depends on (sketch, target/tool bodies,
    /// bodies of face/edge references). Only ids present in the document.
    public func dependencies(of id: UUID) -> Set<UUID> {
        guard let f = feature(id) else { return [] }
        let existing = Set(features.map(\.id))
        return f.referencedFeatures.intersection(existing)
    }

    /// Ids of all features that depend on `id`, directly or transitively, in timeline order.
    public func dependents(of id: UUID) -> [UUID] {
        var affected: Set<UUID> = [id]
        var result: [UUID] = []
        for f in features where f.id != id && !f.referencedFeatures.isDisjoint(with: affected) {
            affected.insert(f.id)
            result.append(f.id)
        }
        return result
    }

    /// Inserts a feature at the rollback marker (or at the end when there is
    /// none) and moves the marker past it so it is active. Returns its index.
    @discardableResult
    public mutating func addFeature(_ feature: Feature) -> Int {
        let index = activeFeatureCount
        features.insert(feature, at: index)
        if rollbackIndex != nil { setRollback(index + 1) }
        return index
    }

    /// Moves the timeline marker: `index` features stay active; `nil` (or ≥ count) = all.
    public mutating func moveRollbackMarker(to index: Int?) {
        guard let index else { rollbackIndex = nil; return }
        setRollback(index)
    }

    /// Deletes a feature. With `cascade`, its (transitive) dependents are deleted too;
    /// otherwise they are kept and reported as broken.
    @discardableResult
    public mutating func deleteFeature(_ id: UUID, cascade: Bool = false) throws -> FeatureDeletion {
        guard index(of: id) != nil else { throw DocumentEditError.featureNotFound(id) }
        let dependents = dependents(of: id)
        let removed = cascade ? [id] + dependents : [id]
        let removedSet = Set(removed)
        if let r = rollbackIndex {
            let removedBeforeMarker = features[..<min(r, features.count)].filter { removedSet.contains($0.id) }.count
            rollbackIndex = r - removedBeforeMarker
        }
        features.removeAll { removedSet.contains($0.id) }
        if let r = rollbackIndex { setRollback(r) }
        pruneHiddenBodies()
        return FeatureDeletion(removed: removed, brokenDependents: cascade ? [] : dependents)
    }

    /// Renames a feature.
    public mutating func renameFeature(_ id: UUID, to name: String) throws {
        guard let i = index(of: id) else { throw DocumentEditError.featureNotFound(id) }
        features[i].name = name
    }

    /// Suppresses or unsuppresses a feature.
    public mutating func setSuppressed(_ id: UUID, _ suppressed: Bool) throws {
        guard let i = index(of: id) else { throw DocumentEditError.featureNotFound(id) }
        features[i].suppressed = suppressed
    }

    /// Replaces a feature's definition (same id), e.g. after editing it in the inspector.
    public mutating func updateFeature(_ feature: Feature) throws {
        guard let i = index(of: feature.id) else { throw DocumentEditError.featureNotFound(feature.id) }
        features[i] = feature
    }

    /// Whether `id` could be moved to `newIndex` without breaking dependency order.
    public func canMoveFeature(_ id: UUID, to newIndex: Int) -> Bool {
        (try? validateMove(id, to: newIndex)) != nil
    }

    /// Moves a feature to `newIndex` (its index after the move). Refuses moves
    /// that would put it before a feature it uses or after one that uses it.
    /// The rollback marker keeps its position.
    public mutating func moveFeature(_ id: UUID, to newIndex: Int) throws {
        let from = try validateMove(id, to: newIndex)
        let f = features.remove(at: from)
        features.insert(f, at: max(0, min(newIndex, features.count)))
    }

    private func validateMove(_ id: UUID, to newIndex: Int) throws -> Int {
        guard let from = index(of: id) else { throw DocumentEditError.featureNotFound(id) }
        let target = max(0, min(newIndex, features.count - 1))
        var order = features
        let f = order.remove(at: from)
        order.insert(f, at: target)
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1.id, $0) })
        for dep in f.referencedFeatures {
            if let p = position[dep], p > target { throw DocumentEditError.dependencyViolation(feature: id, other: dep) }
        }
        for (i, other) in order.enumerated() where i < target && other.referencedFeatures.contains(id) {
            throw DocumentEditError.dependencyViolation(feature: id, other: other.id)
        }
        return from
    }

    private mutating func setRollback(_ index: Int) {
        rollbackIndex = index >= features.count ? nil : max(0, index)
    }
}
