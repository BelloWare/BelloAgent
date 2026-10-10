#!/bin/zsh
# Box engine microbenchmark: shipped Swift sources (e43b1c4) vs rust-branch engines,
# identical inputs, optimized builds, interleaved process runs.
set -eu
M=$WORK/microbench
source $WORK/env.sh
OUT=${OUT:-$M/results-$(date -u +%Y%m%dT%H%M%SZ)}; mkdir -p $OUT
ITER=${ITER:-30}
cd $M/swift && swiftc -O -wmo -target arm64-apple-macosx14.0 DeveloperJSON.swift TextTools.swift main.swift -o $M/swift-bench 2> $OUT/swift-build.log
cd $M/rust && cargo build --release --quiet 2> $OUT/rust-build.log
RB=$CARGO_TARGET_DIR/release/box-engine-bench
{ xcrun swiftc --version; rustc --version; sw_vers; git -C ~/projects/BelloBox-rust rev-parse HEAD; shasum -a 256 $M/swift/*.swift $M/rust/src/main.rs $M/inputs/* $M/swift-bench $RB; } > $OUT/provenance.txt 2>&1
for round in 1 2 3; do
  mkdir -p $OUT/r$round
  if [ $((round % 2)) = 1 ]; then
    $M/swift-bench $M/inputs/json-300k.json $M/inputs/lines-490k.txt $OUT/r$round $ITER > $OUT/r$round/swift.txt
    $RB $M/inputs/json-300k.json $M/inputs/lines-490k.txt $OUT/r$round $ITER > $OUT/r$round/rust.txt
  else
    $RB $M/inputs/json-300k.json $M/inputs/lines-490k.txt $OUT/r$round $ITER > $OUT/r$round/rust.txt
    $M/swift-bench $M/inputs/json-300k.json $M/inputs/lines-490k.txt $OUT/r$round $ITER > $OUT/r$round/swift.txt
  fi
done
echo "== round 1 swift"; cat $OUT/r1/swift.txt; echo "== round 1 rust"; cat $OUT/r1/rust.txt
for op in json.pretty json.minify text.dedupe text.sort text.stats; do
  if cmp -s $OUT/r1/swift-$op.out $OUT/r1/rust-$op.out; then echo "$op: outputs byte-identical"; else echo "$op: OUTPUTS DIFFER ($(wc -c < $OUT/r1/swift-$op.out) vs $(wc -c < $OUT/r1/rust-$op.out) bytes)"; fi
done
echo "out=$OUT"
