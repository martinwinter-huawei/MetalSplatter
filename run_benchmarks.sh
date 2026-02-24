#!/usr/bin/env bash
#
# run_benchmarks.sh
# Runs the MetalSplatter benchmark for every iteration_30000/point_cloud.ply
# found under MODELS_DIR and writes GPU/CPU timings to a CSV file.
#
# Usage:
#   ./run_benchmarks.sh [MODELS_DIR] [OUTPUT_CSV]
#
# Defaults:
#   MODELS_DIR  = /Users/developer/dev/data/models
#   OUTPUT_CSV  = benchmark_results.csv

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP="$SCRIPT_DIR/build/Build/Products/Release/MetalSplatter SampleApp.app/Contents/MacOS/MetalSplatter SampleApp"
MODELS_DIR="${1:-/Users/developer/dev/data/models}"
OUTPUT_CSV="${2:-$SCRIPT_DIR/benchmark_results.csv}"

if [[ ! -x "$APP" ]]; then
    echo "ERROR: App not found or not executable: $APP" >&2
    exit 1
fi

if [[ ! -d "$MODELS_DIR" ]]; then
    echo "ERROR: Models directory not found: $MODELS_DIR" >&2
    exit 1
fi

# Write CSV header
echo "model,num_cameras,cpu_ms,gpu_ms" > "$OUTPUT_CSV"
echo "Writing results to: $OUTPUT_CSV"
echo ""

# Find all point cloud files (bash 3.2-compatible — no mapfile)
PLY_FILES=()
while IFS= read -r f; do
    PLY_FILES+=("$f")
done < <(find "$MODELS_DIR" -path "*/iteration_30000/point_cloud.ply" | grep "exp_true" | sort)

if [[ ${#PLY_FILES[@]} -eq 0 ]]; then
    echo "ERROR: No point_cloud.ply files found under $MODELS_DIR" >&2
    exit 1
fi

echo "Found ${#PLY_FILES[@]} model(s) to benchmark."
echo ""

PASS=0
FAIL=0

for PLY in "${PLY_FILES[@]}"; do
    # Derive a friendly model name from the path
    # e.g. /path/to/models/model_bonsai_exp_true/point_cloud/iteration_30000/point_cloud.ply
    #   -> model_bonsai_exp_true
    MODEL_NAME="$(basename "$(dirname "$(dirname "$(dirname "$PLY")")")")"

    echo "Benchmarking: $MODEL_NAME"
    echo "  PLY: $PLY"

    # Run the benchmark and capture stdout+stderr
    OUTPUT="$("$APP" --benchmark "$PLY" 2>&1)" || true

    # Parse the result line:
    # "Benchmark Finished. Rendered N cameras. Average time CPU X ms, GPU Y ms"
    RESULT_LINE="$(echo "$OUTPUT" | grep '^Benchmark Finished\.' || true)"

    if [[ -z "$RESULT_LINE" ]]; then
        echo "  WARNING: No benchmark result found. Output was:"
        echo "$OUTPUT" | sed 's/^/    /'
        echo "  Skipping."
        FAIL=$((FAIL + 1))
        continue
    fi

    NUM_CAMERAS="$(echo "$RESULT_LINE" | sed -E 's/.*Rendered ([0-9]+) cameras.*/\1/')"
    CPU_MS="$(echo "$RESULT_LINE"      | sed -E 's/.*Average time CPU ([0-9.]+) ms.*/\1/')"
    GPU_MS="$(echo "$RESULT_LINE"      | sed -E 's/.*GPU ([0-9.]+) ms.*/\1/')"

    echo "  Cameras: $NUM_CAMERAS  |  CPU: ${CPU_MS} ms  |  GPU: ${GPU_MS} ms"
    echo "${MODEL_NAME},${NUM_CAMERAS},${CPU_MS},${GPU_MS}" >> "$OUTPUT_CSV"
    PASS=$((PASS + 1))
done

echo ""
echo "Done. $PASS succeeded, $FAIL failed."
echo "Results written to: $OUTPUT_CSV"
