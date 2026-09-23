import Foundation

// Display JSON for the response timeline, built directly: the same value
// `JSON.parse(JSONEncoder().encode(x))` produces, without the encode and
// parse round trip that cost a streaming reply its whole size per token.
// `ResponseTimelineJSONTests` holds the two equal.

extension ResponsePartEvent {
    var displayJSON: JSON {
        var value: JSON = ["attemptID": JSON(attemptID), "ordinal": JSON(ordinal), "itemID": JSON(itemID), "kind": JSON(kind),
                           "update": JSON(update), "text": JSON(text), "evidence": JSON(evidence)]
        if let outputIndex { value["outputIndex"] = JSON(outputIndex) }
        if let partIndex { value["partIndex"] = JSON(partIndex) }
        if let providerSequence { value["providerSequence"] = JSON(providerSequence) }
        if let callID { value["callID"] = JSON(callID) }
        if let name { value["name"] = JSON(name) }
        if let observedAt { value["observedAt"] = JSON(observedAt) }
        if let sessionOrdinal { value["sessionOrdinal"] = JSON(sessionOrdinal) }
        if let reconcilesPartKey { value["reconcilesPartKey"] = JSON(reconcilesPartKey) }
        return value
    }
}

extension ResponseTimeline.Segment {
    /// The segment without its text: every member but the one that grows.
    var displayFields: [String: JSON] { ["id": JSON(id), "state": JSON(state), "truncated": JSON(truncated), "revision": JSON(revision)] }
    var displayJSON: JSON {
        var value = JSON.object(displayFields)
        value["part"] = part.displayJSON; value["text"] = JSON(text)
        return value
    }
}

extension ResponseTimeline {
    /// The timeline without its segments.
    var displayFields: [String: JSON] {
        var value: [String: JSON] = ["version": JSON(version), "coverage": JSON(coverage), "omittedEvents": JSON(omittedEvents)]
        if let terminal { value["terminal"] = JSON(terminal) }
        return value
    }
    var displayJSON: JSON {
        var value = JSON.object(displayFields)
        value["segments"] = .array(segments.map(\.displayJSON))
        return value
    }
}
