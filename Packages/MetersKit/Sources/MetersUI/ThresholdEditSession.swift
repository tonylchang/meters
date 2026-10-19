import MetersCore

/// A module's unfinished numeric pair and validation. Discarding also invalidates native field text.
struct ThresholdEditSession {
    var draft: ThresholdSetting?
    var problem: String?
    /// Whether a field holds text that could not be read. That text never reaches the draft, so only a reset
    /// replaces it.
    var hasUnreadableText = false
    private(set) var revision = 0

    /// A valid pair was saved. Unreadable text left in a field is replaced with the saved value, so no field keeps
    /// text whose problem is no longer shown.
    mutating func commit() {
        if hasUnreadableText { discard() } else { clearDraft() }
    }

    mutating func clearDraft() {
        draft = nil
        problem = nil
    }

    mutating func discard() {
        clearDraft()
        hasUnreadableText = false
        revision += 1
    }
}
