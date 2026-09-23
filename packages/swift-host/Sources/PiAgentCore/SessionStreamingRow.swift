import Foundation

// The streaming row: the reply still arriving, projected at the cost of what
// arrived since the last projection. Until the partial is reset its text,
// thinking and tool inputs only grow, and so does each timeline segment's
// text. Their encoded sizes are running totals and each segment's display
// JSON is kept at its revision, so neither a projection nor the update sent
// to a reader that holds the previous one re-reads the reply so far.

extension AgentSession {
    /// A timeline segment of the streaming row as a projection built it: its
    /// display JSON and exact encoded size at `revision`, and how much of its
    /// text that size covers.
    struct StreamedSegment {
        var revision: Int
        var part: ResponsePartEvent, partJSON: JSON, partBytes: Int
        var textUTF8: Int, textBytes: Int
        var json: JSON, bytes: Int
    }

    /// The segment's display JSON and size, rebuilt only when its revision
    /// moved. A segment's text only grows (appends, or one value replacing an
    /// empty one), so a newer revision adds the size of what was appended.
    func streamedSegment(_ segment: ResponseTimeline.Segment) -> StreamedSegment {
        let previous = streamedSegments[segment.id]
        if let previous, previous.revision == segment.revision { return previous }
        let partJSON: JSON, partBytes: Int
        if let previous, previous.part == segment.part { partJSON = previous.partJSON; partBytes = previous.partBytes }
        else { partJSON = segment.part.displayJSON; partBytes = JSONSize.value(partJSON) }
        let utf8 = segment.text.utf8, textBytes: Int
        if let previous, utf8.count >= previous.textUTF8 {
            textBytes = previous.textBytes + JSONSize.escaped(utf8[utf8.index(utf8.startIndex, offsetBy: previous.textUTF8)...])
        } else { textBytes = JSONSize.escaped(utf8) }
        let fields = segment.displayFields
        var json = JSON.object(fields); json["part"] = partJSON; json["text"] = JSON(segment.text)
        let streamed = StreamedSegment(revision: segment.revision, part: segment.part, partJSON: partJSON, partBytes: partBytes,
                                       textUTF8: utf8.count, textBytes: textBytes, json: json,
                                       bytes: JSONSize.object(fields, sized: ["part": partBytes, "text": 2 + textBytes]))
        streamedSegments[segment.id] = streamed
        return streamed
    }

    /// The streaming row, its exact encoded size, and what a reader that is
    /// sent it holds afterwards.
    func streamingRowProjection(_ id: String) -> (value: JSON, bytes: Int, state: StreamingRowState) {
        var cards: [JSON] = [], cardSizes: [Int] = [], inputs: [String: String] = [:]
        cards.reserveCapacity(partialToolOrder.count); cardSizes.reserveCapacity(partialToolOrder.count)
        for call in partialToolOrder {
            guard var card = partialTools[call] else { continue }
            let input = partialToolInputs[call] ?? ""
            var counted = partialToolInputSizes[call] ?? (0, 0)
            let inputBytes = JSONSize.escaped(input, counted: &counted); partialToolInputSizes[call] = counted
            card["inputBytes"] = JSON(input.utf8.count)
            cardSizes.append(JSONSize.object(card.map, sized: ["input": 2 + inputBytes]))
            card["input"] = JSON(input)
            cards.append(card); inputs[call] = input
        }
        let fields: [String: JSON] = ["id": JSON(id), "role": "assistant", "turn": JSON(currentTurnID), "taskRootID": taskRootID.map { JSON($0) } ?? .null,
                                      "taskExecutionID": activeTaskPresentation.map { JSON($0.executionID) } ?? .null,
                                      "at": partialStartedAt.map { JSON($0) } ?? .null, "state": "streaming", "toolCallCount": 0, "truncated": false]
        var value = JSON.object(fields)
        value["text"] = JSON(partialText); value["thinking"] = JSON(partialThinking); value["tools"] = .array(cards)
        var sized = ["text": 2 + JSONSize.escaped(partialText, counted: &partialTextSize), "thinking": 2 + JSONSize.escaped(partialThinking, counted: &partialThinkingSize),
                     "tools": JSONSize.array(cardSizes)]
        var timeline: ResponseTimeline?
        if !partialTimeline.segments.isEmpty {
            let projected = partialTimeline.projected()
            var segments: [JSON] = [], sizes: [Int] = []
            segments.reserveCapacity(projected.segments.count); sizes.reserveCapacity(projected.segments.count)
            for segment in projected.segments { let streamed = streamedSegment(segment); segments.append(streamed.json); sizes.append(streamed.bytes) }
            let timelineFields = projected.displayFields
            var json = JSON.object(timelineFields); json["segments"] = .array(segments)
            value["responseTimeline"] = json
            sized["responseTimeline"] = JSONSize.object(timelineFields, sized: ["segments": JSONSize.array(sizes)])
            timeline = projected
        }
        let state = StreamingRowState(id: id, generation: partialGeneration, text: partialText, thinking: partialThinking,
                                      cards: partialCardsVersion, truncated: false, inputs: inputs, timeline: timeline)
        return (value, JSONSize.object(fields, sized: sized), state)
    }

    /// What a reader holding `sent` needs to reach `streaming` without the
    /// whole row: the text, thinking and tool input appended since, and the
    /// timeline parts that changed. Nil when only the whole row will do: a
    /// different or reset partial, a card added or changed, or tool input
    /// that grew for a reader that cannot take it as an append.
    func streamingUpdate(from sent: StreamingRowState, to streaming: StreamingRowState, toolInputAppends: Bool) -> (appends: [JSON], parts: [JSON], inputs: [JSON])? {
        guard sent.id == streaming.id, sent.generation == streaming.generation, sent.cards == streaming.cards, sent.truncated == streaming.truncated,
              let text = utf8Suffix(streaming.text, from: sent.text.utf8.count), let thinking = utf8Suffix(streaming.thinking, from: sent.thinking.utf8.count) else { return nil }
        var inputs: [JSON] = []
        for call in streaming.inputs.keys.sorted() {
            let input = streaming.inputs[call] ?? "", held = sent.inputs[call] ?? ""
            guard input.utf8.count != held.utf8.count else { continue }
            guard toolInputAppends, let added = utf8Suffix(input, from: held.utf8.count) else { return nil }
            inputs.append(["id": JSON(streaming.id), "callID": JSON(call), "text": JSON(added), "inputBytes": JSON(input.utf8.count)])
        }
        var parts: [JSON] = []
        if let timeline = streaming.timeline {
            let prior = sent.timeline
            let old = Dictionary((prior?.segments ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            var changed: [JSON] = [], appended: [JSON] = []
            for segment in timeline.segments {
                guard let before = old[segment.id] else { changed.append(streamedSegment(segment).json); continue }
                // A segment's revision moves with every change to it.
                if before.revision == segment.revision { continue }
                if before.part == segment.part, before.truncated == segment.truncated, let added = utf8Suffix(segment.text, from: before.text.utf8.count) {
                    appended.append(["id": JSON(segment.id), "baseRevision": JSON(before.revision), "revision": JSON(segment.revision), "state": JSON(segment.state), "text": JSON(added)])
                } else { changed.append(streamedSegment(segment).json) }
            }
            if !changed.isEmpty || !appended.isEmpty || prior?.terminal != timeline.terminal || prior?.coverage != timeline.coverage || prior?.omittedEvents != timeline.omittedEvents {
                var part: JSON = ["id": JSON(streaming.id), "version": 1, "coverage": JSON(timeline.coverage), "omittedEvents": JSON(timeline.omittedEvents),
                                  "terminal": timeline.terminal.map { JSON($0) } ?? .null, "segments": .array(changed), "appends": .array(appended)]
                if prior?.segments.count != timeline.segments.count || prior?.segments.map(\.id) != timeline.segments.map(\.id) { part["order"] = .array(timeline.segments.map { JSON($0.id) }) }
                parts.append(part)
            }
        }
        let appends: [JSON] = text.isEmpty && thinking.isEmpty ? [] : [["id": JSON(streaming.id), "text": JSON(text), "thinking": JSON(thinking)]]
        return (appends, parts, inputs)
    }
}
