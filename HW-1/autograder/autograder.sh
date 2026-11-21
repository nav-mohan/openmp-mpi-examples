#!/bin/bash
# autograder.sh
# Tests a single student's parallel DTW code for:
#   (1) compilation
#   (2) runtime correctness
#   (3) memory leaks (run separately under Valgrind)
#   (4) unit correctness
#   (5) speedup performance (selected tests, with more than one thread)

THREADS=(1 2 4 8 16 32 64)
declare -A relative_time=(
    [1]=1.0
    [2]=0.6
    [4]=0.36
    [8]=0.216
    [16]=0.130
    [32]=0.078
    [64]=0.047
)

# -------------------------------
# CONFIGURATION VARIABLES
# -------------------------------
tol=.0001                 # numeric tolerance for cost differences
TIMEOUT=45               # timeout for each test in seconds
SERIAL_TIMEOUT=120       # baseline timeout in seconds
VALGRIND_TIMEOUT=120     # memory-check timeout in seconds
COMPILE_TIMEOUT=60       # compilation timeout in seconds

export OMP_PROC_BIND=spread
export OMP_PLACES=cores
export OMP_DYNAMIC=FALSE

mkdir -p result || exit 1
LOGFILE="result/result.txt"
> "$LOGFILE" || exit 1

setup_error() {
    echo "Setup Error: $*" >> "$LOGFILE"
    exit 1
}

# Convert valid numbers to decimal notation so bc also handles scientific
# notation. Reject ambiguous lines, NaN, infinity and invalid signs first.
parse_values() {
    python3 - "$@" <<'PY'
import math, re, sys
from decimal import Decimal
try:
    text = open(sys.argv[1]).read()
    if len(sys.argv) > 2:
        tokens = [text.strip()]
    else:
        tokens = []
        for prefix in ("The Final Cost is:", "The Total Completion time (ms) is:"):
            lines = [line.strip() for line in text.splitlines()
                     if line.strip().startswith(prefix)]
            if len(lines) != 1:
                raise ValueError("missing or duplicate output line")
            tokens.append(lines[0][len(prefix):].strip())
    for token in tokens:
        if not re.fullmatch(r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?", token):
            raise ValueError("invalid number")
        if not math.isfinite(float(token)):
            raise ValueError("non-finite number")
    values = [Decimal(token) for token in tokens]
    if values[0] < 0 or (len(values) == 2 and values[1] <= 0):
        raise ValueError("invalid cost or time")
    print(" ".join(format(value, "f") for value in values))
except (OSError, ValueError):
    sys.exit(1)
PY
}

# -------------------------------
# 1. Variable Preparation
# -------------------------------

# Read settings from config.json
CONFIG_FILE="config.json"

for tool in python3 jq bc timeout grep; do
    command -v "$tool" > /dev/null || setup_error "Missing command: $tool"
done


# Extract speedup indices as a space-separated list
speedup_text=$(jq -r '.speedup_indices[]' "$CONFIG_FILE") || setup_error "Invalid speedup_indices"
SPEEDUP_INDICES=($speedup_text)
[ ${#SPEEDUP_INDICES[@]} -gt 0 ] || setup_error "speedup_indices must not be empty"

# Extract visible indices (used to mask hidden test feedback)
visible_text=$(jq -r '.visible_indices[]' "$CONFIG_FILE") || setup_error "Invalid visible_indices"
VISIBLE_INDICES=($visible_text)

# -------------------------------
# 2. File checking --> Determine that dtw_parallel.c/pp is present, as well as dtw_serial. Set COMPILER + SRC
# -------------------------------

if [ -f "dtw_parallel.cpp" ]; then
    SRC="dtw_parallel.cpp"
    COMPILER="g++"
elif [ -f "dtw_parallel.c" ]; then
    SRC="dtw_parallel.c"
    COMPILER="gcc"
else
    echo "Exit Error: ❌ No source file found (dtw_parallel.c or dtw_parallel.cpp missing)!" >> "$LOGFILE"
    exit 1
fi

# Check for serial executable
command -v "$COMPILER" > /dev/null || setup_error "Missing compiler: $COMPILER"
if [ ! -x "./dtw_serial" ]; then
    setup_error "Missing dtw_serial executable — cannot run baseline tests."
fi


# -------------------------------
# 3. Random Valgrind index selection
# -------------------------------

# Get all visible indices that are NOT speedup indices
# We do this as valgrind takes too long to complete
NON_SPEEDUP_VISIBLE_INDICES=()
for idx in "${VISIBLE_INDICES[@]}"; do
    if [[ ! " ${SPEEDUP_INDICES[@]} " =~ " ${idx} " ]]; then
        NON_SPEEDUP_VISIBLE_INDICES+=("$idx")
    fi
done

# Choose one of these non-speedup indices at random for valgrind testing
if [ ${#NON_SPEEDUP_VISIBLE_INDICES[@]} -gt 0 ]; then
    VALGRIND_INDEX=${NON_SPEEDUP_VISIBLE_INDICES[$((RANDOM % ${#NON_SPEEDUP_VISIBLE_INDICES[@]}))]}
else
    setup_error "Memory check needs a visible input outside speedup_indices"
fi
command -v valgrind > /dev/null || setup_error "Missing command: valgrind"

echo "Selected test index ${VALGRIND_INDEX} (visible, non-speedup) for memory leak check" >> "$LOGFILE"



# -------------------------------
# 4. Compilation --> compile the parallel code
# -------------------------------
# Compile the parallel code
timeout --kill-after=5s ${COMPILE_TIMEOUT}s "$COMPILER" -O3 -fopenmp "$SRC" -o dtw_parallel -lm > result/compile.txt 2>&1
if [ $? -ne 0 ]; then
    echo "Exit Error: ❌ Compilation failed!" >> "$LOGFILE"
    exit 1
fi
echo "✅ Compilation successful!" >> "$LOGFILE"


# -------------------------------
# 5. Test Loop
# -------------------------------

# Check for test input files in the tests/ directory
shopt -s nullglob
test_files=()
TEST_INDICES=()
declare -A expected_costs
for candidate in tests/testin_*.txt; do
    if [[ "$candidate" =~ ^tests/testin_(0|[1-9][0-9]*)\.txt$ ]] && [ -f "$candidate" ]; then
        i=${BASH_REMATCH[1]}
        test_files+=("$candidate")
        TEST_INDICES+=("$i")
        expected_costs[$i]=$(parse_values "tests/testout_${i}.txt" expected) || setup_error "Missing or invalid tests/testout_${i}.txt"
    fi
done
if [ ${#test_files[@]} -eq 0 ]; then
    setup_error "No test input files found in tests/ directory!"
fi
for idx in "${SPEEDUP_INDICES[@]}" "${VISIBLE_INDICES[@]}"; do
    [[ " ${TEST_INDICES[*]} " == *" $idx "* ]] || setup_error "Configured test $idx is missing"
done

# Run tests
for input in "${test_files[@]}"; do
    i=${input#tests/testin_}
    i=${i%.txt}

    input="tests/testin_${i}.txt"
    expected_output="tests/testout_${i}.txt"
    expected_cost=${expected_costs[$i]}
    mkdir -p "result/test_$i" || setup_error "Cannot create result/test_$i"
    echo "=== Testing $input ===" >> "$LOGFILE"

    # -------------------------------
    # Run serial version once per test to get baseline
    # -------------------------------
    serial_out="result/test_$i/result_serial.txt"
    echo "--- Running serial version ---" >> "$LOGFILE"

    timeout --kill-after=5s ${SERIAL_TIMEOUT}s ./dtw_serial "$input" > "$serial_out" 2>&1
    if [ $? -ne 0 ]; then
        setup_error "Runtime error or timeout in serial execution on $input"
    else
        serial_values=$(parse_values "$serial_out") || setup_error "Invalid serial output on $input"
        read -r base_cost base_time_ms <<< "$serial_values"
        echo "Serial baseline: cost=$base_cost, time=${base_time_ms}ms" >> "$LOGFILE"
    fi

    for t in "${THREADS[@]}"; do
        outfile="result/test_$i/result_${t}_threads.txt"
        valfile="result/test_$i/valgrind_${t}.txt"

        echo "--- Running $t threads (main run) ---" >> "$LOGFILE"

        # -------------------
        # Valgrind run (memory leaks) on specific index with number of threads equal to 1 only
        # -------------------
        if [ "$i" -eq "$VALGRIND_INDEX" ] && [ "$t" -eq 1 ]; then
            echo "--- Running $t threads (valgrind) ---" >> "$LOGFILE"
            timeout --kill-after=5s ${VALGRIND_TIMEOUT}s valgrind --leak-check=full --show-leak-kinds=all \
                --errors-for-leak-kinds=definite,indirect --error-exitcode=99 ./dtw_parallel "$input" "$t" \
                > /dev/null 2> "$valfile"
            val_exit=$?
            # Ignore reachable/possible runtime allocations; catch invalid
            # accesses, undefined values and definite/indirect application leaks.
            if [ "$val_exit" -eq 124 ] || [ "$val_exit" -eq 137 ]; then
                echo "Memory error on $input with $t threads (Valgrind timeout)" >> "$LOGFILE"
            elif ! grep -q "ERROR SUMMARY:" "$valfile"; then
                setup_error "Valgrind did not finish correctly; see $valfile"
            elif [ "$val_exit" -ne 0 ]; then
                echo "Memory error on $input with $t threads (see $valfile)" >> "$LOGFILE"
            fi
        fi


        # -------------------
        # Normal run (runtime + unit + speedup)
        # -------------------
        timeout --kill-after=5s ${TIMEOUT}s ./dtw_parallel "$input" "$t" > "$outfile" 2>&1
        exit_code=$?

        # (a) Handle timeout and other runtime errors
        if [ $exit_code -eq 124 ]; then
            echo "Timeout on $input with $t threads (exceeded ${TIMEOUT}s)" >> "$LOGFILE"
            echo "Runtime error on $input with $t threads (timeout causes failure)" >> "$LOGFILE"
            echo "Unit test fails on $input with $t threads (timeout causes failure)" >> "$LOGFILE"
            if [ "$t" -gt 1 ] && [[ " ${SPEEDUP_INDICES[@]} " =~ " ${i} " ]]; then
                echo "Speedup failure on $input with $t threads (runtime error causes failure)" >> "$LOGFILE"
            fi
            echo "Completed case on $input with $t threads" >> "$LOGFILE"
            continue
        fi

        # (b) Runtime errors with helpful error code information
        if [ $exit_code -ne 0 ]; then
            echo "Runtime error on $input with $t threads (exit code: $exit_code)" >> "$LOGFILE"
            echo "Unit test fails on $input with $t threads (runtime error causes failure)" >> "$LOGFILE"
            if [ "$t" -gt 1 ] && [[ " ${SPEEDUP_INDICES[@]} " =~ " ${i} " ]]; then
                echo "Speedup failure on $input with $t threads (runtime error causes failure)" >> "$LOGFILE"
            fi
            echo "Completed case on $input with $t threads" >> "$LOGFILE"
            continue
        fi

        # (c) Extract cost/time
        if ! values=$(parse_values "$outfile"); then
            echo "Runtime error on $input with $t threads: incorrectly printed output" >> "$LOGFILE"
            echo "Unit test fails on $input with $t threads (runtime error causes failure)" >> "$LOGFILE"
            if [ "$t" -gt 1 ] && [[ " ${SPEEDUP_INDICES[@]} " =~ " ${i} " ]]; then
                echo "Speedup failure on $input with $t threads (runtime error causes failure)" >> "$LOGFILE"
            fi
            echo "Completed case on $input with $t threads" >> "$LOGFILE"
            continue
        fi
        read -r cost time_ms <<< "$values"

        # (d) Unit test correctness
        diff=$(echo "d=$expected_cost-$cost; if (d<0) -d else d" | bc -l)
        if (( $(echo "$diff >= $tol" | bc -l) )); then
            echo "Unit test fails on $input with $t threads" >> "$LOGFILE"
            if [ "$t" -gt 1 ] && [[ " ${SPEEDUP_INDICES[@]} " =~ " ${i} " ]]; then
                echo "Speedup failure on $input with $t threads (unit test error causes failure)" >> "$LOGFILE"
            fi
            echo "Completed case on $input with $t threads" >> "$LOGFILE"
            continue
        fi

        # (e) Speedup checks only for selected indices in config.json, excluding the t=1 condition
        if [ "$t" -gt 1 ] && [[ " ${SPEEDUP_INDICES[@]} " =~ " ${i} " ]]; then
            threshold=${relative_time[$t]}
            rel_current=$(echo "$time_ms / $base_time_ms" | bc -l)
            if [ "$(echo "$rel_current > $threshold" | bc -l)" -eq 1 ]; then
                echo "Speedup failure on $input with $t threads" >> "$LOGFILE"
            fi
        fi
        echo "Completed case on $input with $t threads" >> "$LOGFILE"
    done
done
echo "Autograder completed successfully" >> "$LOGFILE"
