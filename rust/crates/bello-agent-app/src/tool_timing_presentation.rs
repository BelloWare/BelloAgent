//! Swift main f4f80ddd TranscriptActivity.formatDuration / RowParts.elapsed.
//! Whole-unit integer rounding avoids overflow for retained u64 values.
use bello_agent_core::{Session, tool_timing::DurationUs};

pub(crate) fn format_duration(duration: DurationUs) -> String {
    let us = duration.get();
    let tenths = us / 100_000 + u64::from(us % 100_000 >= 50_000);
    if tenths < 10 {
        // Match Swift's printf formatting, including binary floating-point ties.
        // This conversion is bounded below one second; huge values stay integer.
        let ms = us as f64 / 1_000.;
        return format!("{:.1}s", ms / 1_000.);
    }
    let seconds = us / 1_000_000 + u64::from(us % 1_000_000 >= 500_000);
    if seconds < 60 {
        return format!("{seconds}s");
    }
    let (minutes, rest) = (seconds / 60, seconds % 60);
    if minutes < 60 {
        return if rest > 0 {
            format!("{minutes}m {rest}s")
        } else {
            format!("{minutes}m")
        };
    }
    let (hours, rest) = (minutes / 60, minutes % 60);
    if rest > 0 {
        format!("{hours}h {rest}m")
    } else {
        format!("{hours}h")
    }
}

pub(crate) fn elapsed(duration: Option<DurationUs>) -> Option<String> {
    duration
        .filter(|value| value.get() >= 50_000)
        .map(format_duration)
}

/// Only the committed sum of batch wall observations, never model/task time or
/// the sum of overlapping calls. Unknown legacy history is not fabricated zero.
pub(crate) fn total_label(session: &Session) -> String {
    match session.tool_timing.and_then(|timing| timing.total_us) {
        Some(total) => format!("Tool time {}", format_duration(total)),
        None => "Tool time n/a".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bello_agent_core::tool_timing::SessionToolTiming;

    #[test]
    fn source_duration_boundaries_and_huge_retained_values() {
        for (us, expected) in [
            (0, "0.0s"),
            (49_000, "0.0s"),
            (49_999, "0.0s"),
            (50_000, "0.1s"),
            (150_000, "0.1s"),
            (250_000, "0.2s"),
            (350_000, "0.3s"),
            (450_000, "0.5s"),
            (750_000, "0.8s"),
            (850_000, "0.8s"),
            (949_000, "0.9s"),
            (950_000, "1s"),
            (990_000, "1s"),
            (59_499_999, "59s"),
            (59_500_000, "1m"),
            (60_500_000, "1m 1s"),
            (3_599_499_999, "59m 59s"),
            (3_599_500_000, "1h"),
            (3_660_000_000, "1h 1m"),
            (u64::MAX, "5124095576h 1m"),
        ] {
            assert_eq!(format_duration(DurationUs::new(us)), expected, "{us}");
        }
        assert_eq!(elapsed(None), None);
        assert_eq!(elapsed(Some(DurationUs::new(49_999))), None);
        assert_eq!(
            elapsed(Some(DurationUs::new(50_000))).as_deref(),
            Some("0.1s")
        );
    }

    #[test]
    fn footer_uses_only_committed_batch_total_and_preserves_unknown() {
        let mut session = Session::new();
        session.tool_timing = None;
        assert_eq!(total_label(&session), "Tool time n/a");
        session.tool_timing = Some(SessionToolTiming { total_us: None });
        assert_eq!(total_label(&session), "Tool time n/a");
        session.tool_timing = Some(SessionToolTiming {
            total_us: Some(DurationUs::new(990_000)),
        });
        assert_eq!(total_label(&session), "Tool time 1s");
        session.state = bello_agent_core::RunState::Running;
        assert_eq!(total_label(&session), "Tool time 1s");
    }
    #[test]
    fn checked_microseconds_match_captured_native_swift_formatter() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../docs/validation/tool-timing-2026-10-08/native-formatter/outputs.json"
        ))
        .unwrap();
        let mut checked = 0;
        for case in fixture["results"].as_array().unwrap() {
            let Some(us) = case["checked_microseconds"]
                .as_str()
                .and_then(|value| value.parse::<u64>().ok())
            else {
                continue;
            };
            assert_eq!(
                format_duration(DurationUs::new(us)),
                case["formatted"].as_str().unwrap(),
                "{}",
                case["id"]
            );
            checked += 1;
        }
        assert_eq!(checked, 36, "every representable native case must run");
    }
}
