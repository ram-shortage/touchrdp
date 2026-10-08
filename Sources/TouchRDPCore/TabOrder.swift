import Foundation

// MARK: - Session tab ordering (F-7)

/// Pure ordering logic for the runtime session-tab strip. The order is an array of
/// session IDs owned by the view layer (runtime-only, never persisted); every mutation
/// goes through these total, predictable helpers so the semantics are validated
/// headlessly (ValidateCore): new tabs append, closing keeps the remaining order,
/// drag-to-reorder moves only IDs (never the sessions themselves).
public enum SessionTabOrder {
    /// Append `id` if it's not already present. New sessions go to the end; re-opening
    /// an existing tab (reconnect) keeps its slot.
    public static func appending<ID: Equatable>(_ id: ID, to order: [ID]) -> [ID] {
        order.contains(id) ? order : order + [id]
    }

    /// Remove `id`, keeping the relative order of the remaining tabs.
    public static func removing<ID: Equatable>(_ id: ID, from order: [ID]) -> [ID] {
        order.filter { $0 != id }
    }

    /// Move `id` so it occupies the slot currently held by `target` (live
    /// drag-to-reorder: called as the dragged tab passes over another tab; works in both
    /// directions). No-op when either ID is missing or they are the same.
    public static func moving<ID: Equatable>(_ id: ID, toSlotOf target: ID,
                                             in order: [ID]) -> [ID] {
        guard id != target,
              let from = order.firstIndex(of: id),
              let to = order.firstIndex(of: target) else { return order }
        var result = order
        result.remove(at: from)
        result.insert(id, at: to)
        return result
    }

    /// The tab to select after closing `id` while it was active: its right-hand
    /// neighbour, else the new last tab, else nil (no tabs left). `order` is the
    /// pre-close order (must still contain `id` for neighbour semantics).
    public static func selectionAfterClosing<ID: Equatable>(_ id: ID, in order: [ID]) -> ID? {
        let remaining = removing(id, from: order)
        guard !remaining.isEmpty else { return nil }
        guard let idx = order.firstIndex(of: id) else { return remaining.last }
        return remaining[min(idx, remaining.count - 1)]
    }

    // MARK: Tear-off windows (F-16)

    /// Detach `id` into its own window: it leaves the tab order, and — when it was the
    /// active tab — the selection falls back exactly like closing it (right-hand
    /// neighbour, else the new last tab, else nil). An inactive detach never moves the
    /// selection. `order` is the pre-detach order (must still contain `id`).
    public static func detaching<ID: Equatable>(_ id: ID, from order: [ID],
                                                active: ID?) -> (order: [ID], active: ID?) {
        let newActive = (active == id) ? selectionAfterClosing(id, in: order) : active
        return (removing(id, from: order), newActive)
    }

    /// Reattach a torn-off session to the main window: it re-enters the tab order at
    /// the END (or keeps its slot in the degenerate already-present case).
    public static func reattaching<ID: Equatable>(_ id: ID, to order: [ID]) -> [ID] {
        appending(id, to: order)
    }
}
