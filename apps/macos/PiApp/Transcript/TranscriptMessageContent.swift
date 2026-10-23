import Foundation

@MainActor enum TranscriptMessageContentClock { static var allocations = 0 }

/// Allocated only for image messages. Immutable references let a message
/// change without changing an earlier page's copy of it.
final class TranscriptImageContent: Sendable, Equatable {
    struct Images: Sendable, Equatable {
        var count: Int? = nil
        var only: Bool? = nil
        var reference: TranscriptImageReference? = nil
        var attachments: [AttachmentRecord]? = nil
        var isEmpty: Bool { count == nil && only == nil && reference == nil && attachments == nil }
    }
    let images: Images
    init(images: Images) {
        self.images = images
        if Thread.isMainThread {
            MainActor.assumeIsolated { if TranscriptLayoutClock.recording { TranscriptMessageContentClock.allocations += 1 } }
        }
    }
    static func == (lhs: TranscriptImageContent, rhs: TranscriptImageContent) -> Bool {
        lhs === rhs || lhs.images == rhs.images
    }
}

extension TranscriptMessage {
    var imageCount: Int? {
        get { imageContent?.images.count }
        set { if newValue != imageCount { changeImages { $0.count = newValue } } }
    }
    var imageOnly: Bool? {
        get { imageContent?.images.only }
        set { if newValue != imageOnly { changeImages { $0.only = newValue } } }
    }
    var imageReference: TranscriptImageReference? {
        get { imageContent?.images.reference }
        set { if newValue != imageReference { changeImages { $0.reference = newValue } } }
    }
    /// The optimistic Sending row still owns the submitted file references.
    var imageAttachments: [AttachmentRecord]? {
        get { imageContent?.images.attachments }
        set { if newValue != imageAttachments { changeImages { $0.attachments = newValue } } }
    }
    private mutating func changeImages(_ change: (inout TranscriptImageContent.Images) -> Void) {
        var next = imageContent?.images ?? TranscriptImageContent.Images()
        change(&next)
        imageContent = next.isEmpty ? nil : TranscriptImageContent(images: next)
    }

    /// Keep the helper's flat display-row shape; storage is an app detail.
    private enum CodingKeys: String, CodingKey {
        case id, role, text, thinking, tools, state, truncated, stopReason, accounting, kind, nativeAgentDelivery, agentNumbers, detail
        case at, turn, modelMs, toolCallCount, taskRootID, taskExecutionID, presentationSourceID, operationID, toolCallID, responseTimeline, foldGroup
        case skills, imageCount, imageOnly, imageReference, imageAttachments, reply, failureCode, versions, requestAttemptIDs, earlierVersion
    }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try fields.decode(String.self, forKey: .id), role: try fields.decode(String.self, forKey: .role), text: try fields.decode(String.self, forKey: .text))
        thinking = try fields.decodeIfPresent(String.self, forKey: .thinking)
        tools = try fields.decodeIfPresent([ToolView].self, forKey: .tools)
        state = try fields.decodeIfPresent(String.self, forKey: .state)
        truncated = try fields.decodeIfPresent(Bool.self, forKey: .truncated)
        stopReason = try fields.decodeIfPresent(String.self, forKey: .stopReason)
        accounting = try fields.decodeIfPresent(GatewayTotals.self, forKey: .accounting)
        kind = try fields.decodeIfPresent(String.self, forKey: .kind)
        nativeAgentDelivery = try fields.decodeIfPresent(WireValue.self, forKey: .nativeAgentDelivery)
        agentNumbers = try fields.decodeIfPresent([String: Int].self, forKey: .agentNumbers)
        detail = try fields.decodeIfPresent(String.self, forKey: .detail)
        at = try fields.decodeIfPresent(Double.self, forKey: .at)
        turn = try fields.decodeIfPresent(String.self, forKey: .turn)
        modelMs = try fields.decodeIfPresent(Double.self, forKey: .modelMs)
        toolCallCount = try fields.decodeIfPresent(Int.self, forKey: .toolCallCount)
        taskRootID = try fields.decodeIfPresent(String.self, forKey: .taskRootID)
        taskExecutionID = try fields.decodeIfPresent(String.self, forKey: .taskExecutionID)
        presentationSourceID = try fields.decodeIfPresent(String.self, forKey: .presentationSourceID)
        operationID = try fields.decodeIfPresent(String.self, forKey: .operationID)
        toolCallID = try fields.decodeIfPresent(String.self, forKey: .toolCallID)
        responseTimeline = try fields.decodeIfPresent(ResponseTimeline.self, forKey: .responseTimeline)
        foldGroup = try fields.decodeIfPresent(String.self, forKey: .foldGroup)
        skills = try fields.decodeIfPresent([TranscriptSkillUse].self, forKey: .skills)
        let images = TranscriptImageContent.Images(count: try fields.decodeIfPresent(Int.self, forKey: .imageCount),
            only: try fields.decodeIfPresent(Bool.self, forKey: .imageOnly), reference: try fields.decodeIfPresent(TranscriptImageReference.self, forKey: .imageReference),
            attachments: try fields.decodeIfPresent([AttachmentRecord].self, forKey: .imageAttachments))
        if !images.isEmpty { imageContent = TranscriptImageContent(images: images) }
        reply = try fields.decodeIfPresent(ReplyRecord.self, forKey: .reply)
        failureCode = try fields.decodeIfPresent(String.self, forKey: .failureCode)
        versions = try fields.decodeIfPresent(MessageVersionMark.self, forKey: .versions)
        requestAttemptIDs = try fields.decodeIfPresent([String].self, forKey: .requestAttemptIDs)
        earlierVersion = try fields.decodeIfPresent(Bool.self, forKey: .earlierVersion)
    }
    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(id, forKey: .id); try fields.encode(role, forKey: .role); try fields.encode(text, forKey: .text)
        try fields.encodeIfPresent(thinking, forKey: .thinking)
        try fields.encodeIfPresent(tools, forKey: .tools)
        try fields.encodeIfPresent(state, forKey: .state)
        try fields.encodeIfPresent(truncated, forKey: .truncated)
        try fields.encodeIfPresent(stopReason, forKey: .stopReason)
        try fields.encodeIfPresent(accounting, forKey: .accounting)
        try fields.encodeIfPresent(kind, forKey: .kind)
        try fields.encodeIfPresent(nativeAgentDelivery, forKey: .nativeAgentDelivery)
        try fields.encodeIfPresent(agentNumbers, forKey: .agentNumbers)
        try fields.encodeIfPresent(detail, forKey: .detail)
        try fields.encodeIfPresent(at, forKey: .at)
        try fields.encodeIfPresent(turn, forKey: .turn)
        try fields.encodeIfPresent(modelMs, forKey: .modelMs)
        try fields.encodeIfPresent(toolCallCount, forKey: .toolCallCount)
        try fields.encodeIfPresent(taskRootID, forKey: .taskRootID)
        try fields.encodeIfPresent(taskExecutionID, forKey: .taskExecutionID)
        try fields.encodeIfPresent(presentationSourceID, forKey: .presentationSourceID)
        try fields.encodeIfPresent(operationID, forKey: .operationID)
        try fields.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try fields.encodeIfPresent(responseTimeline, forKey: .responseTimeline)
        try fields.encodeIfPresent(foldGroup, forKey: .foldGroup)
        try fields.encodeIfPresent(skills, forKey: .skills)
        if let images = imageContent?.images {
            try fields.encodeIfPresent(images.count, forKey: .imageCount)
            try fields.encodeIfPresent(images.only, forKey: .imageOnly)
            try fields.encodeIfPresent(images.reference, forKey: .imageReference)
            try fields.encodeIfPresent(images.attachments, forKey: .imageAttachments)
        }
        try fields.encodeIfPresent(reply, forKey: .reply)
        try fields.encodeIfPresent(failureCode, forKey: .failureCode)
        try fields.encodeIfPresent(versions, forKey: .versions)
        try fields.encodeIfPresent(requestAttemptIDs, forKey: .requestAttemptIDs)
        try fields.encodeIfPresent(earlierVersion, forKey: .earlierVersion)
    }
}
