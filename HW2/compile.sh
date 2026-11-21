mkdir build;
mpicc -O3 -std=c99 -o build/variable_cannon variable_cannon.c -lm
mpicc -O3 -std=c99 -o build/square_cannon square_cannon.c -lm
