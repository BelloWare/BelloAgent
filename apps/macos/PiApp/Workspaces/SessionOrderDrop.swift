import SwiftUI

struct SessionOrderDrop: DropDelegate {
    let model: WorkspaceModel
    let projectID: String, targetID: String
    let height: CGFloat
    @Binding var insertionAfter: Bool?
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [TopicSessionDrag.type]) }
    func dropEntered(info: DropInfo) { insertionAfter = info.location.y > height / 2 }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        insertionAfter = info.location.y > height / 2
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { insertionAfter = nil }
    func performDrop(info: DropInfo) -> Bool {
        let after = info.location.y > height / 2; insertionAfter = nil
        return TopicSessionDrag.accept(info.itemProviders(for: [TopicSessionDrag.type]), in: projectID) { ids in
            try await model.reorderSessions(ids, relativeTo: targetID, after: after, in: projectID)
        } failure: { model.error = $0 }
    }
}
