    nonisolated static func elapsed(of tool: ToolView) -> String? {
        guard TranscriptActivity.outcome(of: tool) != .running, let ms = tool.durationMs, ms >= 50 else { return nil }
        return TranscriptActivity.formatDuration(ms)
    }
