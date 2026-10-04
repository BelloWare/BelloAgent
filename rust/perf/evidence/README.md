# Benchmark evidence availability

This public checkpoint includes source code, reproducible benchmark/comparison
scripts, aggregate results, test/review findings, and relevant implementation
hashes. Historical raw benchmark samples, diagnostic logs, detailed environment
records, manifests, and their compressed archive are **retained locally and are
not published in this repository**.

The baseline, buffered-snapshot, and journal reports clearly identify this limit.
Historical aggregate claims cannot be independently recomputed from the public
checkpoint alone. Running the supplied harness creates fresh local evidence;
those results will reflect the new machine and source revision. These synthetic
measurements are not displayed-frame-rate, GPU-present, app-wide, or Swift-relative
performance claims.

The local raw records and archive were preserved unchanged. No archive parts or
raw diagnostics are required to compile or test the application. The gitignore
keeps new raw outputs and local evidence packages out of ordinary source commits.
The optional package-evidence.py utility can package newly generated local runs;
its presence does not imply that a historical archive is available here.
