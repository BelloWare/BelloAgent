// Engine microbenchmark around the rust-branch bellobox-core engines used by the
// Rust app (developer::execute("json", ..), text::lines, text::counts). Not a UI test.
use bellobox_core::{developer, text};
use std::time::Instant;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    assert_eq!(args.len(), 5, "usage: bench JSON TEXT OUTDIR ITERATIONS");
    let json = std::fs::read_to_string(&args[1]).unwrap();
    let input = std::fs::read_to_string(&args[2]).unwrap();
    let out_dir = std::path::PathBuf::from(&args[3]);
    let iterations: usize = args[4].parse().unwrap();
    let mut report = serde_json::Map::new();
    let mut bench = |name: &str, body: &dyn Fn() -> String| {
        let mut output = String::new();
        for _ in 0..3 {
            output = body();
        }
        let mut samples = Vec::with_capacity(iterations);
        for _ in 0..iterations {
            let t0 = Instant::now();
            output = std::hint::black_box(body());
            samples.push(t0.elapsed().as_secs_f64() * 1000.0);
        }
        std::fs::write(out_dir.join(format!("rust-{name}.out")), &output).unwrap();
        let mut s = samples.clone();
        s.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let p = |q: f64| s[((s.len() as f64 * q).ceil() as usize).clamp(1, s.len()) - 1];
        println!(
            "{name:<14} p50 {:8.2} ms  p90 {:8.2} ms  min {:8.2} ms  out {} B",
            p(0.5),
            p(0.9),
            s[0],
            output.len()
        );
        report.insert(
            name.into(),
            serde_json::json!({"n": s.len(), "min": s[0], "p50": p(0.5), "p90": p(0.9),
                "max": s[s.len() - 1], "outputBytes": output.len(), "samplesMs": samples}),
        );
    };
    bench("json.pretty", &|| developer::execute("json", &json, "pretty").unwrap());
    bench("json.minify", &|| developer::execute("json", &json, "minify").unwrap());
    bench("text.dedupe", &|| text::lines(&input, text::LineOperation::Unique));
    bench("text.sort", &|| text::lines(&input, text::LineOperation::Sort));
    bench("text.stats", &|| {
        let c = text::counts(&input, "");
        format!("{} {} {} {}", c.characters, c.without_whitespace, c.words, c.lines)
    });
    std::fs::write(
        out_dir.join("rust-results.json"),
        serde_json::to_string_pretty(&report).unwrap(),
    )
    .unwrap();
}
