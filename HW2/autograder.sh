#!/bin/bash
# =======================================================
# Cannon’s Algorithm Distributed Test Runner (Round Robin)
# =======================================================

set -e  # stop on any failure

PROGRAM="variable_cannon"  # target source (variable_cannon.c)
HOSTFILE="hosts.txt"       # contains both csel-plate001 and csel-plate002
TEST_DIR="tests"           # location of test_0, test_1, test_2 directories
BUILD_DIR="build"          # build output directory

mkdir -p "$BUILD_DIR"

# -------------------------------
# (1) Compile the C program
# -------------------------------
echo "🔧 Compiling $PROGRAM.c ..."
if ! mpicc -O3 -std=c99 -o "$BUILD_DIR/$PROGRAM" "$PROGRAM.c" -lm; then
    echo "❌ Compilation failed."
    exit 1
fi
echo "✅ Compilation successful."
echo

# -------------------------------
# (2) Helper function to run test
# -------------------------------
run_test() {
    local test_id=$1
    local np=$2

    local input="$TEST_DIR/test_${test_id}/in.txt"
    local ref_output="$TEST_DIR/test_${test_id}/out.txt"
    local tmp_output="$BUILD_DIR/out_test${test_id}_np${np}.txt"
    local log_file="$BUILD_DIR/log_test${test_id}_np${np}.txt"

    if [ ! -f "$input" ] || [ ! -f "$ref_output" ]; then
        echo "⚠️  Missing input or reference output for test_${test_id}"
        return
    fi

    # --------------------------
    # Timeout and thresholds
    # --------------------------
    local timeout_val=5
    declare -A max_times=(
        [1]=4.0 [4]=1.0 [9]=0.5 [16]=0.25
        [25]=0.15 [36]=0.12 [49]=0.10 [64]=0.10
    )
    if [ "$test_id" -eq 11 ]; then
        timeout_val=20
    fi

    echo "🚀 Running test_${test_id} with -np ${np} (timeout=${timeout_val}s) ..."

    # --------------------------
    # Run with timeout + runtime-error detection
    # --------------------------
    set +e
    timeout "${timeout_val}s" mpirun -np "$np" \
        --hostfile "$HOSTFILE" \
        --map-by node \
        "$BUILD_DIR/$PROGRAM" "$input" "$tmp_output" \
        >"$log_file" 2>&1
    local exit_code=$?
    set -e

    if [ $exit_code -eq 124 ]; then
        echo "⏱️  test_${test_id} (np=${np}) TIMEOUT after ${timeout_val}s"
        echo
        rm -f "$tmp_output" "$log_file"
        return
    elif [ $exit_code -ne 0 ]; then
        echo "💥 test_${test_id} (np=${np}) RUNTIME ERROR (exit code $exit_code)"
        echo "🔍 See $log_file for details"
        echo
        rm -f "$tmp_output" "$log_file"
        return
    fi

    # --------------------------
    # Compare against reference
    # --------------------------
    echo "🔍 Comparing output with reference..."
    if diff -q "$tmp_output" "$ref_output" > /dev/null; then
        echo "✅ UNIT TEST PASSED: test_${test_id} (np=${np})"
    else
        echo "❌ UNIT TEST FAILED: test_${test_id} (np=${np})"
        if [ "$test_id" -eq 11 ]; then
            echo "❌ test_11 (np=${np}) SPEEDUP FAIL: skipping speedup check due to incorrect output"
            echo
            rm -f "$tmp_output" "$log_file"
            return
        fi
    fi

    # --------------------------
    # Speedup timing check (only for test 11)
    # --------------------------
    if [ "$test_id" -eq 11 ]; then
        local elapsed
        elapsed=$(grep "Time for matrix multiplication:" "$log_file" | awk '{print $5}')
        if [ -z "$elapsed" ]; then
            echo "⚠️  test_11 (np=${np}) SPEEDUP FAIL: elapsed time not found in log"
        else
            local threshold=${max_times[$np]:-0}
            if (( $(awk -v e="$elapsed" -v t="$threshold" 'BEGIN{print (e>t)?1:0}') )); then
                echo "❌ test_11 (np=${np}) SPEEDUP FAIL: ${elapsed}s (threshold=${threshold}s)"
            else
                echo "✅ test_11 (np=${np}) SPEEDUP PASS: ${elapsed}s (threshold=${threshold}s)"
            fi
        fi
    fi

    # --------------------------
    # Cleanup temporary files
    # --------------------------
    rm -f "$tmp_output" "$log_file"

    echo
}


# -------------------------------
# (3) Execute square matrix tests
# -------------------------------
echo "======================================================================================================"
echo "Running Square Matrix Tests"
echo "======================================================================================================"
# A (2x2) x B (2x2)
for np in 1 4; do
    run_test 0 "$np"
done

# A (5x5) x B (5x5)
for np in 1 25; do
    run_test 1 "$np"
done

# A (4x4) x B (4x4)
for np in 1 4 16; do
    run_test 2 "$np"
done

# A (10x10) x B (10x10)
for np in 1 4 25; do
    run_test 3 "$np"
done

# A (36x36) x B (36x36)
for np in 1 4 9 16 36; do
    run_test 4 "$np"
done


# -------------------------------
# (4) Execute divisible matrices tests
# -------------------------------
echo "======================================================================================================"
echo "Running Divisible Matrix Tests (all matrices are divisble by sqrt(p))"
echo "======================================================================================================"
# A (2x4) x B (4x6)
for np in 1 4; do
    run_test 5 "$np"
done

# A (3x6) x B (6x9)
for np in 1 9; do
    run_test 6 "$np"
done

# A (5x10) x B (10x25)
for np in 1 25; do
    run_test 7 "$np"
done

# -------------------------------
# (5) Execute prime dimension tests
# -------------------------------
echo "======================================================================================================"
echo "Running Prime Dimension Matrix Tests (there will be leftover rows/columns as m,n,k % sqrt(p) != 0)"
echo "======================================================================================================"
# TEST 8 --> A (11x13) B (13x17)
# TEST 9 --> A (13x17) B (17x19)
# TEST 10 --> A (17x19) B (19x23)
for test_id in 8 9 10; do
    for np in 1 4 9 16 25 36 49 64; do
        run_test "$test_id" "$np"
    done
done

# -------------------------------
# (6) Execute timing test
# -------------------------------
echo "======================================================================================================"
echo "Running Timing Test (Large Matrix)"
echo "======================================================================================================"
#TEST 11 --> A (1009x1007) B (1007x1019)
for np in 1 4 9 16 25 36 49 64; do
    run_test 11 "$np"
done

echo "All tests complete."