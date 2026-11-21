#/bin/sh

export OMP_PROC_BIND=spread;
export OMP_PLACES=cores;

# SERIAL: unoptimized. debug symbols
# gcc -O0 -fopenmp my_dtw_serial.c -o my_dtw_serial.out -lm;

# SERIAL: optimized build
# gcc -O3 -fopenmp my_dtw_serial.c -o my_dtw_serial.out -lm;

# run with GDB
# gdb --args my_dtw_serial tests/testin_5.txt;


# PARALLEL: unoptimized build
# gcc -O0 -fopenmp dtw_parallel.c -o a.out -lm;

# PARALLEL: optimized build
#gcc -O3 -fopenmp hydra.c -o dtw_parallel -lm;
gcc -O3 -fopenmp plate1.c -o dtw_parallel -lm;


# run with GDB
# gdb --args dtw_parallel tests/testin_5.txt 4 128;

