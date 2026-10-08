//! Monotonic observations only. Missing observations never become inferred zero.
use serde::{Deserialize, Serialize};
use std::time::{Duration, Instant};

/// Checked integer microseconds. JSON negatives, fractions and out-of-range
/// values are rejected, rather than silently coercing malformed observations.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct DurationUs(u64);
impl DurationUs {
    pub const ZERO: Self = Self(0);
    pub const fn new(value: u64) -> Self {
        Self(value)
    }
    pub const fn get(self) -> u64 {
        self.0
    }
    pub fn from_duration(value: Duration) -> Option<Self> {
        u64::try_from(value.as_micros()).ok().map(Self)
    }
    pub fn since(start: Instant) -> Option<Self> {
        Instant::now()
            .checked_duration_since(start)
            .and_then(Self::from_duration)
    }
    pub fn checked_add(self, other: Self) -> Option<Self> {
        self.0.checked_add(other.0).map(Self)
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BatchTiming {
    #[serde(deserialize_with = "required_observation")]
    pub wall_us: Option<DurationUs>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SessionToolTiming {
    #[serde(deserialize_with = "required_observation")]
    pub total_us: Option<DurationUs>,
}
impl SessionToolTiming {
    pub const ZERO: Self = Self {
        total_us: Some(DurationUs::ZERO),
    };
    pub(crate) fn adding(previous: Option<Self>, batch: BatchTiming) -> Self {
        Self {
            total_us: previous
                .and_then(|p| p.total_us)
                .zip(batch.wall_us)
                .and_then(|(a, b)| a.checked_add(b)),
        }
    }
}

fn required_observation<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<DurationUs>, D::Error> {
    Option::<DurationUs>::deserialize(deserializer)
}
