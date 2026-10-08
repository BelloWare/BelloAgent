#[derive(Clone,Copy)]
struct DurationUs(u64); impl DurationUs {fn get(self)->u64 {self.0}}
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


fn main(){
let value=DurationUs(0); assert_eq!(format_duration(value),"0.0s","ms:0"); assert_eq!(elapsed(Some(value)).as_deref(),None,"ms:0");
let value=DurationUs(49000); assert_eq!(format_duration(value),"0.0s","ms:49"); assert_eq!(elapsed(Some(value)).as_deref(),None,"ms:49");
let value=DurationUs(50000); assert_eq!(format_duration(value),"0.1s","ms:50"); assert_eq!(elapsed(Some(value)).as_deref(),Some("0.1s"),"ms:50");
let value=DurationUs(149000); assert_eq!(format_duration(value),"0.1s","ms:149"); assert_eq!(elapsed(Some(value)).as_deref(),Some("0.1s"),"ms:149");
let value=DurationUs(150000); assert_eq!(format_duration(value),"0.1s","ms:150"); assert_eq!(elapsed(Some(value)).as_deref(),Some("0.1s"),"ms:150");
let value=DurationUs(249000); assert_eq!(format_duration(value),"0.2s","ms:249"); assert_eq!(elapsed(Some(value)).as_deref(),Some("0.2s"),"ms:249");
let value=DurationUs(250000); assert_eq!(format_duration(value),"0.2s","ms:250"); assert_eq!(elapsed(Some(value)).as_deref(),Some("0.2s"),"ms:250");
let value=DurationUs(251000); assert_eq!(format_duration(value),"0.3s","ms:251"); assert_eq!(elapsed(Some(value)).as_deref(),Some("0.3s"),"ms:251");
let value=DurationUs(349000); assert_eq!(format_duration(value),"0.3s","ms:349"); assert_eq!(elapsed(Some(value)).as_deref(),Some("0.3s"),"ms:349");
let value=DurationUs(350000); assert_eq!(format_duration(value),"0.3s","ms:350"); assert_eq!(elapsed(Some(value)).as_deref(),Some("0.3s"),"ms:350");
let value=DurationUs(450000); assert_eq!(format_duration(value),"0.5s","ms:450"); assert_eq!(elapsed(Some(value)).as_deref(),Some("0.5s"),"ms:450");
let value=DurationUs(550000); assert_eq!(format_duration(value),"0.6s","ms:550"); assert_eq!(elapsed(Some(value)).as_deref(),Some("0.6s"),"ms:550");
let value=DurationUs(650000); assert_eq!(format_duration(value),"0.7s","ms:650"); assert_eq!(elapsed(Some(value)).as_deref(),Some("0.7s"),"ms:650");
let value=DurationUs(750000); assert_eq!(format_duration(value),"0.8s","ms:750"); assert_eq!(elapsed(Some(value)).as_deref(),Some("0.8s"),"ms:750");
let value=DurationUs(850000); assert_eq!(format_duration(value),"0.8s","ms:850"); assert_eq!(elapsed(Some(value)).as_deref(),Some("0.8s"),"ms:850");
let value=DurationUs(949000); assert_eq!(format_duration(value),"0.9s","ms:949"); assert_eq!(elapsed(Some(value)).as_deref(),Some("0.9s"),"ms:949");
let value=DurationUs(950000); assert_eq!(format_duration(value),"1s","ms:950"); assert_eq!(elapsed(Some(value)).as_deref(),Some("1s"),"ms:950");
let value=DurationUs(951000); assert_eq!(format_duration(value),"1s","ms:951"); assert_eq!(elapsed(Some(value)).as_deref(),Some("1s"),"ms:951");
let value=DurationUs(990000); assert_eq!(format_duration(value),"1s","ms:990"); assert_eq!(elapsed(Some(value)).as_deref(),Some("1s"),"ms:990");
let value=DurationUs(1000000); assert_eq!(format_duration(value),"1s","ms:1000"); assert_eq!(elapsed(Some(value)).as_deref(),Some("1s"),"ms:1000");
let value=DurationUs(1499000); assert_eq!(format_duration(value),"1s","ms:1499"); assert_eq!(elapsed(Some(value)).as_deref(),Some("1s"),"ms:1499");
let value=DurationUs(1500000); assert_eq!(format_duration(value),"2s","ms:1500"); assert_eq!(elapsed(Some(value)).as_deref(),Some("2s"),"ms:1500");
let value=DurationUs(59499000); assert_eq!(format_duration(value),"59s","ms:59499"); assert_eq!(elapsed(Some(value)).as_deref(),Some("59s"),"ms:59499");
let value=DurationUs(59500000); assert_eq!(format_duration(value),"1m","ms:59500"); assert_eq!(elapsed(Some(value)).as_deref(),Some("1m"),"ms:59500");
let value=DurationUs(59999000); assert_eq!(format_duration(value),"1m","ms:59999"); assert_eq!(elapsed(Some(value)).as_deref(),Some("1m"),"ms:59999");
let value=DurationUs(60000000); assert_eq!(format_duration(value),"1m","ms:60000"); assert_eq!(elapsed(Some(value)).as_deref(),Some("1m"),"ms:60000");
let value=DurationUs(3599499000); assert_eq!(format_duration(value),"59m 59s","ms:3599499"); assert_eq!(elapsed(Some(value)).as_deref(),Some("59m 59s"),"ms:3599499");
let value=DurationUs(3599500000); assert_eq!(format_duration(value),"1h","ms:3599500"); assert_eq!(elapsed(Some(value)).as_deref(),Some("1h"),"ms:3599500");
let value=DurationUs(3600000000); assert_eq!(format_duration(value),"1h","ms:3600000"); assert_eq!(elapsed(Some(value)).as_deref(),Some("1h"),"ms:3600000");
let value=DurationUs(49999); assert_eq!(format_duration(value),"0.0s","ms:49.999"); assert_eq!(elapsed(Some(value)).as_deref(),None,"ms:49.999");
let value=DurationUs(149999); assert_eq!(format_duration(value),"0.1s","ms:149.999"); assert_eq!(elapsed(Some(value)).as_deref(),Some("0.1s"),"ms:149.999");
let value=DurationUs(949999); assert_eq!(format_duration(value),"0.9s","ms:949.999"); assert_eq!(elapsed(Some(value)).as_deref(),Some("0.9s"),"ms:949.999");
let value=DurationUs(59499999); assert_eq!(format_duration(value),"59s","ms:59499.999"); assert_eq!(elapsed(Some(value)).as_deref(),Some("59s"),"ms:59499.999");
let value=DurationUs(60500000); assert_eq!(format_duration(value),"1m 1s","ms:60500"); assert_eq!(elapsed(Some(value)).as_deref(),Some("1m 1s"),"ms:60500");
let value=DurationUs(3599499999); assert_eq!(format_duration(value),"59m 59s","ms:3599499.999"); assert_eq!(elapsed(Some(value)).as_deref(),Some("59m 59s"),"ms:3599499.999");
let value=DurationUs(3660000000); assert_eq!(format_duration(value),"1h 1m","ms:3660000"); assert_eq!(elapsed(Some(value)).as_deref(),Some("1h 1m"),"ms:3660000");
println!("36 exact production Rust formatting/threshold cases match native Swift oracle");}
