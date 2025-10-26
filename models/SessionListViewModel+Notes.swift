import Foundation

@MainActor
extension SessionListViewModel {
    func beginEditing(session: SessionSummary) async {
        editingSession = session
        if let note = await notesStore.note(for: session.id) {
            editTitle = note.title ?? ""
            editComment = note.comment ?? ""
        } else {
            editTitle = session.userTitle ?? ""
            editComment = session.userComment ?? ""
        }
    }

    func saveEdits() async {
        guard let session = editingSession else { return }
        let titleValue = editTitle.isEmpty ? nil : editTitle
        let commentValue = editComment.isEmpty ? nil : editComment
        await notesStore.upsert(id: session.id, title: titleValue, comment: commentValue)
        notesSnapshot[session.id] = SessionNote(
            id: session.id, title: titleValue, comment: commentValue, updatedAt: Date())
        var map = Dictionary(uniqueKeysWithValues: allSessions.map { ($0.id, $0) })
        if var s = map[session.id] {
            s.userTitle = titleValue
            s.userComment = commentValue
            map[session.id] = s
        }
        allSessions = Array(map.values)
        applyFilters()
        cancelEdits()
    }

    func cancelEdits() {
        editingSession = nil
        editTitle = ""
        editComment = ""
    }
}
