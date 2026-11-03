#define _POSIX_C_SOURCE 200809L  // enables getline() and ssize_t on most compilers
#include <sys/types.h>
#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>


/* ---------- Matrix reading from file (use streaming for very large files >500MB) ---------- */
void read_matrix_streaming(const char *filename, double **A, double **B, 
    int *rows_A, int *cols_A, int *rows_B, int *cols_B) 
    {
    FILE *fp = fopen(filename, "r");
    if (!fp) { perror("fopen"); MPI_Abort(MPI_COMM_WORLD, 1); }

    char *line = NULL;
    size_t len = 0;
    ssize_t read;
    int readingA = 0, readingB = 0;
    int rowsA = 0, colsA = 0, rowsB = 0, colsB = 0;

    // First pass — determine dimensions
    while ((read = getline(&line, &len, fp)) != -1) {
        if (strncmp(line, "Matrix A", 8) == 0) { readingA = 1; readingB = 0; continue; }
        if (strncmp(line, "Matrix B", 8) == 0) { readingA = 0; readingB = 1; continue; }
        if (!readingA && !readingB) continue;

        int count = 0;
        char *tmp = strtok(line, " \t\n");
        while (tmp) { count++; tmp = strtok(NULL, " \t\n"); }
        if (count == 0) continue;

        if (readingA) { rowsA++; colsA = count; }
        else if (readingB) { rowsB++; colsB = count; }
    }

    rewind(fp);

    *rows_A = rowsA;
    *rows_B = rowsB;
    *cols_A = colsA;
    *cols_B = colsB;
    
    *A = malloc(rowsA * colsA * sizeof(double));
    *B = malloc(rowsB * colsB * sizeof(double));

    int idxA = 0, idxB = 0;
    readingA = readingB = 0;

    // Second pass — parse data directly into flat arrays
    while ((read = getline(&line, &len, fp)) != -1) {
        if (strncmp(line, "Matrix A", 8) == 0) { readingA = 1; readingB = 0; continue; }
        if (strncmp(line, "Matrix B", 8) == 0) { readingA = 0; readingB = 1; continue; }
        if (!readingA && !readingB) continue;

        char *tmp = strtok(line, " \t\n");
        while (tmp) {
            double val = atof(tmp);
            if (readingA) (*A)[idxA++] = val;
            else if (readingB) (*B)[idxB++] = val;
            tmp = strtok(NULL, " \t\n");
        }
    }

    free(line);
    fclose(fp);
}


/* ---------- Local matrix multiplication ---------- */
// multiply a pair of A-B blocks of size (brows_A x bcols_A) and (brows_B x bcols_B)
// to get a C-block of dim (brows_C x bcols_C)
void MatrixMultiply(double *A, double *B, double *C, 
    int brows_A, int bcols_A, 
    int brows_B, int bcols_B, 
    int brows_C, int bcols_C
) 
{
    printf("MatrixMultiply\n");
    for (int i = 0; i < brows_C; i++)
        for (int j = 0; j < bcols_B; j++)
            for (int k = 0; k < brows_B; k++)
                C[i*bcols_C + j] += A[i*bcols_A + k] * B[k*bcols_B + j];
}

/* ---------- Write matrix to output file ---------- */
// account for the padding and only write out the top-left (rows_C x cols_C) part of C
// you'll still need pcols_C to get the pointer arithmetic right
void write_matrix_to_file(const char *filename, double *C, int rows_C, int cols_C, int pcols_C) 
    {
    FILE *fp = fopen(filename, "w");
    if (!fp) {
        fprintf(stderr, "Error: Cannot open output file %s\n", filename);
        MPI_Abort(MPI_COMM_WORLD, 1);
    }

    for (int i = 0; i < rows_C; i++) {
        for (int j = 0; j < cols_C; j++) {
            fprintf(fp, "%.4f", C[i * pcols_C + j]);
            if (j < cols_C - 1) fprintf(fp, " ");
        }
        fprintf(fp, "\n");
    }
    fclose(fp);
}

/* ---------- Debug: Print matrix ---------- */
void PrintMatrix(int rows, int cols, double* mat) {
    for (int i = 0; i < rows; i++) {
        for (int j = 0; j < cols; j++) {
            printf("%8.2f ", mat[i * cols + j]);
        }
        printf("\n");
    }
}

/* ---------- Create Cartesian grid communicator ---------- */
// nlocal_out is the size of the block matrices in A,B,C. 
// now we need 3 integers to specify the size of block-matrices in A,B,C
MPI_Comm create_cartesian_grid(MPI_Comm base_comm, int * brows_A, int * bcols_A, int * brows_B, int * bcols_B, int * proc_grid_size, int rows_A, int cols_A, int rows_B, int cols_B)
{
    printf("create_cartesian_grid\n");
    int npes;
    MPI_Comm_size(base_comm, &npes);

    int dims[2] = {0, 0}; // square matrix of process-grid. dims[0] = dims[1] = \sqrt{npes}
    MPI_Dims_create(npes, 2, dims);

    int periods[2] = {1, 1};  /* wraparound grid for Cannon */
    MPI_Comm grid;
    MPI_Cart_create(base_comm, 2, dims, periods, 1, &grid);

    // dims[0] == dims[1] -- square matrix of process grid
    // remember to round up the block-sizes in anticipatoin of making rows_A a multiple of dims[0]
    if (brows_A) *brows_A = (rows_A + dims[0] - 1) / dims[0];
    if (bcols_A) *bcols_A = (cols_A + dims[0] - 1) / dims[0];
    if (brows_B) *brows_B = (rows_B + dims[0] - 1) / dims[0];
    if (bcols_B) *bcols_B = (cols_B + dims[0] - 1) / dims[0];
    if (proc_grid_size) *proc_grid_size = dims[0];

    return grid;
}

/* ---------- Scatter global n×n matrix into nlocal×nlocal blocks ---------- */
// A_matrix is the global padding-adjusted matrix of dimension (prows x pcols) 
// each block within the gpam matrix is a (brows x bcols) block 
void scatter_2d_blocks(double *A_global, double *local,
                       int prows, int pcols, 
                       int brows, int bcols, 
                       MPI_Comm grid)
{
    printf("scatter_2d_blocks\n");
    int npes, rank;
    MPI_Comm_size(grid, &npes);
    MPI_Comm_rank(grid, &rank);

    int dims[2], coords[2];
    MPI_Cart_get(grid, 2, dims, (int[]){1,1}, coords);

    if (rank == 0) { // rank 0 does the scattering
        for (int r = 0; r < npes; r++) // loop over all processes (including rank 0)
        {
            int rc[2]; // coordinates of rank r
            MPI_Cart_coords(grid, r, 2, rc); // get coordinates for rank r

            int sizes[2]    = { prows, pcols }; // size of global padding-adjusted matrix
            int subsizes[2] = { brows, bcols }; // size of each block within gpam
            int starts[2]   = { rc[0]*brows, rc[1]*bcols }; // block's top-left corner

            MPI_Datatype sub;
            MPI_Type_create_subarray(2, sizes, subsizes, starts,
                                     MPI_ORDER_C, MPI_DOUBLE, &sub);
            MPI_Type_commit(&sub);

            if (r == 0) // if rank 0 then do a simple memcpy() because src_rank = dst_rank
            {
                // copy first block from global to local
                //  copy each brow individually
                for (int i = 0; i < brows; i++) 
                { 
                    const double *src = A_global + (starts[0]+i)*pcols + starts[1]; // first block
                    double *dst = local + i*bcols;
                    memcpy(dst, src, bcols * sizeof(double));
                }
            } else { // if not rank 0 then perform actual send()
                MPI_Send(A_global, 1, sub, r, 999, grid);
            }
            MPI_Type_free(&sub);
        }
    } else {
        MPI_Recv(local, brows*bcols, MPI_DOUBLE, 0, 999, grid, MPI_STATUS_IGNORE);
    }
}

/* ---------- Gather nlocal×nlocal blocks back into global n×n matrix ---------- */
// the C_matrix is the global padding-adjusted product matrix. dim = (prows x pcols)
// each blick within the gpam C_matrix is (brows x bcols) block
void gather_2d_blocks(double *local, double *C_global,
                        int prows, int pcols, 
                        int brows, int bcols,
                        MPI_Comm grid)
{
    printf("gather_2d_blocks\n");
    int npes, rank;
    MPI_Comm_size(grid, &npes);
    MPI_Comm_rank(grid, &rank);

    int dims[2], coords[2];
    MPI_Cart_get(grid, 2, dims, (int[]){1,1}, coords);
    // int nlocal = n / dims[0]; // nlocal is now replaced by brows or bcols where applicable

    if (rank == 0) // rank 0 gathers from all other ranks into gpam C_matrix
    { 
        for (int r = 0; r < npes; r++) 
        {
            int rc[2]; // grid coordinate of rank r
            MPI_Cart_coords(grid, r, 2, rc); // get grid coordinate of rank r

            int sizes[2]    = { prows, pcols };
            int subsizes[2] = { brows, bcols };
            int starts[2]   = { rc[0]*brows, rc[1]*bcols };

            MPI_Datatype sub;
            MPI_Type_create_subarray(2, sizes, subsizes, starts,
                                     MPI_ORDER_C, MPI_DOUBLE, &sub);
            MPI_Type_commit(&sub);

            if (r == 0) // if rank 0, do simple memcpy() from local block into global C_matrix
            {
                // copy first block from local to global
                //  copy each brow individually
                for (int i = 0; i < brows; i++) 
                {
                    double *dst = C_global + (starts[0]+i)*pcols + starts[1];
                    const double *src = local + i*bcols;
                    memcpy(dst, src, bcols * sizeof(double));
                }
            } else { // if not rank 0, do recv()
                MPI_Recv(C_global, 1, sub, r, 1999, grid, MPI_STATUS_IGNORE);
            }
            MPI_Type_free(&sub);
        }
    } else { // if not rank 0 do a send 
        MPI_Send(local, prows*pcols, MPI_DOUBLE, 0, 1999, grid);
    }
}

void MatrixMatrixMultiply(double *a, double *b, double *c, 
                            int brows_A, int bcols_A, 
                            int brows_B, int bcols_B, 
                            int brows_C, int bcols_C, 
                            MPI_Comm grid)
{
    printf("MatrixMatrixMultiply\n");
    int i;
    int npes, myrank, mycoords[2];
    int dims[2], periods[2];
    int uprank, downrank, leftrank, rightrank;
    int shiftsource, shiftdest;
    MPI_Status status;

    /* Query communicator info from the existing grid */
    MPI_Comm_size(grid, &npes);
    MPI_Comm_rank(grid, &myrank);
    MPI_Cart_get(grid, 2, dims, periods, mycoords);

    /* Determine neighbors for shifts */
    MPI_Cart_shift(grid, 1, +1, &leftrank, &rightrank);  // left/right along columns
    MPI_Cart_shift(grid, 0, +1, &uprank, &downrank);     // up/down along rows

    /* ---------- Initial alignment ---------- */
    MPI_Cart_shift(grid, 1, -mycoords[0], &shiftsource, &shiftdest);
    MPI_Sendrecv_replace(a, brows_A * bcols_A, MPI_DOUBLE,
                         shiftdest, 100,
                         shiftsource, 100, grid, &status);

    MPI_Cart_shift(grid, 0, -mycoords[1], &shiftsource, &shiftdest);
    MPI_Sendrecv_replace(b, brows_B * bcols_B, MPI_DOUBLE,
                         shiftdest, 200,
                         shiftsource, 200, grid, &status);


    /* ---------- Main Cannon loop ---------- */
    for (i = 0; i < dims[0]; i++) { // iteratee over each block of rows
        MatrixMultiply(a, b, c, brows_A, bcols_A, brows_B, bcols_B, brows_C, bcols_C);

        /* Rotate A left */
        MPI_Sendrecv_replace(a, brows_A * bcols_A, MPI_DOUBLE,
                             leftrank, 1000 + i,
                             rightrank, 1000 + i, grid, &status);

        /* Rotate B up */
        MPI_Sendrecv_replace(b, brows_B * bcols_B, MPI_DOUBLE,
                             uprank, 2000 + i,
                             downrank, 2000 + i, grid, &status);
    }

    /* ---------- Restore original distribution ---------- */
    MPI_Cart_shift(grid, 1, +mycoords[0], &shiftsource, &shiftdest);
    MPI_Sendrecv_replace(a, brows_A * bcols_A, MPI_DOUBLE,
                         shiftdest, 300,
                         shiftsource, 300, grid, &status);

    MPI_Cart_shift(grid, 0, +mycoords[1], &shiftsource, &shiftdest);
    MPI_Sendrecv_replace(b, brows_B * bcols_B, MPI_DOUBLE,
                         shiftdest, 400,
                         shiftsource, 400, grid, &status);
}



/* ---------- Main ---------- */
int main(int argc, char *argv[]) {
    MPI_Init(&argc, &argv);

    int rank, npes;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &npes);

    if (argc < 3) {
        if (rank == 0)
            fprintf(stderr, "Usage: %s <input_file> <output_file>\n", argv[0]);
        MPI_Finalize();
        return 1;
    }

    const char *input_file = argv[1];
    const char *output_file = argv[2];

    double *A = NULL, *B = NULL, *C = NULL, *C_full = NULL;
    int rows_A, rows_B, cols_A, cols_B, rows_C, cols_C;
    int brows_A, bcols_A, brows_B, bcols_B, brows_C, bcols_C;
    int q; // q x q process-grid 

    if (rank == 0)
    {
        read_matrix_streaming(input_file, &A, &B, &rows_A, &cols_A, &rows_B, &cols_B);

        // sanity check
        if (rows_B != cols_A)
        {
            fprintf(stderr,"invalid input. A has dimensions %d x %d. B has dimension %d x %d. cols_A should equal rows_B\n", rows_A,cols_A,rows_B,cols_B); fflush(stdout);
            MPI_Finalize();
            return 1;
        }
    }
    rows_C = rows_A;
    cols_C = cols_A;

    printf("start bcast for rows_A = %d, rows_B = %d, cols_A = %d, cols_B = %d \n",rows_A,rows_B,cols_A,cols_B);
    printf("rank %d before bcast\n", rank); fflush(stdout);
    MPI_Bcast(&rows_A, 1, MPI_INT, 0, MPI_COMM_WORLD);
    MPI_Bcast(&rows_B, 1, MPI_INT, 0, MPI_COMM_WORLD);
    MPI_Bcast(&cols_A, 1, MPI_INT, 0, MPI_COMM_WORLD);
    MPI_Bcast(&cols_B, 1, MPI_INT, 0, MPI_COMM_WORLD);
    MPI_Bcast(&rows_C, 1, MPI_INT, 0, MPI_COMM_WORLD);
    MPI_Bcast(&cols_C, 1, MPI_INT, 0, MPI_COMM_WORLD);
    printf("done bcast for rows/cols of A,B,C\n");

    /* Create Cartesian grid once and reuse */
    MPI_Comm grid = create_cartesian_grid(MPI_COMM_WORLD, 
        &brows_A, &bcols_A, &brows_B, &bcols_B, 
        &q, 
        rows_A, cols_A, rows_B, cols_B
    );
    brows_C = brows_A;
    bcols_C = bcols_B;

    // brows_A, bcols_A, bcols_B are the padding-adjusted block-sizes 
    // so padding-adjusted matrix sizes will be proc_grid_size * block-sizes
    int prows_A, prows_B, pcols_A, pcols_B, prows_C, pcols_C;
    prows_A = q * brows_A;
    pcols_A = q * bcols_A;
    prows_B = q * brows_B;
    pcols_B = q * bcols_B;
    prows_C = prows_A;
    pcols_C = pcols_B;

    double *a_local = malloc(brows_A * bcols_A * sizeof(double));
    double *b_local = malloc(brows_B * bcols_B * sizeof(double));
    C = calloc(brows_C * bcols_C, sizeof(double));

    // allocate padding-adjusted global-matrix dims
    double * A_pad;
    double * B_pad;
    if(rank == 0)
    {    
        A_pad = malloc(prows_A * pcols_A * sizeof(double));
        B_pad = malloc(prows_B * pcols_B * sizeof(double));
        memset(A_pad, 0, (prows_A * pcols_A * sizeof(double)));
        memset(B_pad, 0, (prows_B * pcols_B * sizeof(double)));
        // copy from unpadded global-mats A into padded global-mats A
        for (int r = 0; r < rows_A; r++)
        {
            const int row_start_idx_pad = r*pcols_A; // the rth row starts at pointer r*pcols_A in the padded matrix
            const int row_start_idx_orig = r*cols_A; // the rth row starts at pointer r*cols_A in the original matrix
            double * dst = A_pad + row_start_idx_pad;
            double * src = A + row_start_idx_orig;
            const size_t row_size_orig = cols_A * sizeof(double); // we need copy only only cols_A doubles from each row. 
            memcpy(dst,src,row_size_orig);
        }
        // copy from unpadded global-mats B into padded global-mats B
        for (int r = 0; r < rows_B; r++)
        {
            const int row_start_idx_pad = r*pcols_B;
            const int row_start_idx_orig = r*cols_B;
            double * dst = B_pad + row_start_idx_pad;
            double * src = B + row_start_idx_orig;
            const size_t row_size_orig = cols_B * sizeof(double);
            memcpy(dst,src,row_size_orig);
        }
    }
    /* Proper 2D scatter */
    scatter_2d_blocks(A_pad, a_local, prows_A, pcols_A, brows_A, bcols_A, grid);
    scatter_2d_blocks(B_pad, b_local, prows_B, pcols_B, brows_B, bcols_B, grid);

    double start, end, elapsed;
    start = MPI_Wtime();
    /* Run Cannon’s algorithm */
    MatrixMatrixMultiply(a_local, b_local, C, brows_A, bcols_A, brows_B, bcols_B, brows_C, bcols_C, grid);
    end = MPI_Wtime();
    if (rank == 0) {
        elapsed = end - start;
        printf("Time for matrix multiplication: %.6f seconds\n", elapsed);
    }

    /* Gather result back */
    if (rank == 0)
        C_full = malloc(prows_C * pcols_C * sizeof(double));
    gather_2d_blocks(C, C_full, prows_C, pcols_C, brows_C, bcols_C, grid);

    /* Write result to output file */
    printf("Writing to file\n");
    if (rank == 0) {
        write_matrix_to_file(output_file, C_full, rows_C,cols_C,pcols_C);
        printf("Result written to %s\n", output_file);
        free(A);
        free(B);
        free(C_full);
    }
    printf("Done Writing to file\n");

    MPI_Comm_free(&grid);
    free(a_local);
    free(b_local);
    free(C);

    MPI_Finalize();
    return 0;
}