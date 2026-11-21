#!/bin/bash

# Define the executable and the fixed input file
EXEC="./dtw_parallel"
INPUT_FILE="tests/testin_5.txt"
CSV_FILE="benchmark_results.csv"

# Check if the executable exists
if [ ! -x "$EXEC" ]; then
    echo "Error: $EXEC does not exist or is not executable."
    exit 1
fi

# Write the CSV header line
echo "NUM_THREADS,BLOCK_SIZE,TIME,FINAL_COST" > "$CSV_FILE"

# Define the array for NUM_THREADS
THREADS_LIST=(2 4 8 16 32 64 128)

echo "Starting benchmarks. Results will be saved to $CSV_FILE..."

# Loop through each thread configuration
for threads in "${THREADS_LIST[@]}"; do
    # Loop through NUM_BLOCKS in powers of 2 from 2 up to 2048
    for ((blocks=1; blocks<=4096; blocks*=2)); do
        echo "Running: $EXEC $INPUT_FILE $threads $blocks"
        
        # Run the executable and capture its standard output
        output=$($EXEC "$INPUT_FILE" "$threads" "$blocks")
        
        # Parse out the cost and time using grep and sed/awk
        final_cost=$(echo "$output" | grep "The Final Cost is:" | awk '{print $NF}')
        total_time=$(echo "$output" | grep "The Total Completion time (ms) is:" | awk '{print $NF}')
        
        # Fallback to 'N/A' if the program failed to output the expected values
        if [ -z "$final_cost" ]; then final_cost="N/A"; fi
        if [ -z "$total_time" ]; then total_time="N/A"; fi
        
        # Append the parsed data as a new row in the CSV file
        echo "$threads,$blocks,$total_time,$final_cost" >> "$CSV_FILE"
    done
done

echo "Benchmarks complete! Output saved to $CSV_FILE."
