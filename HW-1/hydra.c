#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <math.h>

#include <omp.h>

// utility function to find the minimum of 3 floats
double find_min3(const double a, const double b, const double c)
{
        double min = a;
        if (b < min) min = b;
        if (c < min) min = c;
        return min;
}

// a struct for storing size of data 
struct data_size 
{
        int rows_A;
        int cols_A;
        int rows_B;
        int cols_B;
};

// do a first pass over the file and get the size of the matrices 
const struct data_size get_data_size(FILE * f)
{
        int rows_A = 0, cols_A =0, rows_B = 0, cols_B = 0;

        // first pass - count size of data 
        char * line;
        int current_matrix = 0; // currently parsing this matrix. 1 for A. 2 for B
        size_t read;
        size_t linelen = 0;
        while((read = getline(&line, &linelen, f)) != -1)
        {
                // printf("%d | %s",linelen,line);

                if(strncmp(line,"Matrix A",8) == 0) // if "Matrix A"
                {
                        // printf("found A\n");
                        current_matrix = 1;
                        continue;
                }

                if(strncmp(line,"Matrix B",8) == 0) // if "Matrix A"
                {
                        // printf("found B\n");
                        current_matrix = 2;
                        continue;
                }

                if (current_matrix == 1) // parsing matrix A
                {
                        rows_A++;
                        if(cols_A == 0)
                        {
                                int spaces = 0;
                                for (int i = 0; line[i] != '\0'; i++)
                                {
                                        if(line[i] == ' ') spaces++;
                                }
                                cols_A = spaces+1;
                        }
                }

                if (current_matrix == 2) // parsing matrix 2
                {
                        rows_B++;
                        if(cols_B == 0)
                        {
                                int spaces = 0;
                                for (int i = 0; line[i] != '\0'; i++)
                                {
                                        if(line[i] == ' ') spaces++;
                                }
                                cols_B = spaces+1;
                        }
                }
        }
        // printf("dim(A) = %d X %d\n",rows_A,cols_A);
        // printf("dim(B) = %d X %d\n",rows_B,cols_B);
        
        // sanity check - A nad B should have equal column size
        if(cols_A != cols_B)
        {
                printf("ERROR: Matrix A and Matrix B have different column width\n");
                printf("ERROR: cols_A = %d | cols_B = %d\n",cols_A,cols_B);
        }

        const struct data_size ds ={rows_A,cols_A,rows_B,cols_B};
        return ds;
}

// do a second pass over the file and get the actual data out
void get_data(FILE * f, const struct data_size ds, double *A, double *B)
{
        int rows_A = ds.rows_A;
        int rows_B = ds.rows_B;
        int cols_A = ds.cols_A;
        int cols_B = ds.cols_B;

        // second pass - actually read in the values of A and B 
        rewind(f);
        while(fgetc(f) != '\n'){}; // skip the line "Matrix A"
        
        for (int k = 0; k < rows_A*cols_A; k++) fscanf(f,"%lf",&A[k]); 
        
        while(fgetc(f) != '\n'){}; // skip until we hit newline char of last row of A
        while(fgetc(f) != '\n'){}; // skip the line "Matrix B"

        for (int k = 0; k < rows_B*cols_B; k++) fscanf(f,"%lf",&B[k]); 
        fclose(f);
}

int main(int argc, char * argv[])
{
        // validate input 
        if (argc < 3)
        {
                fprintf(stderr, "USAGE: %s <test_file> <num_threads>\n",argv[0]);
                return EXIT_FAILURE;
        }

        int NUM_THREADS = atoi(argv[2]);
        if (NUM_THREADS < 1) NUM_THREADS = 1;

        omp_set_dynamic(0); // disable dynamic thread spawning 
        omp_set_num_threads(NUM_THREADS);


        // read in file
        FILE *f = fopen(argv[1], "r");
        if (f == NULL) 
        {
                printf("Failed to open file %s\n", argv[1]);
                exit(1);
        }

        const struct data_size ds = get_data_size(f);
        const int rows_A = ds.rows_A;
        const int cols_A = ds.cols_A;
        const int rows_B = ds.rows_B;
        const int cols_B = ds.cols_B;

        // points for matrix A,B
        double * A = malloc(rows_A * cols_A * sizeof(double));
        double * B = malloc(rows_B * cols_B * sizeof(double));

        // second pass - actually read in the values of A and B 
        get_data(f,ds,A,B);
        
        double *dist = malloc(rows_A * rows_B * sizeof(double));
        double * DP = malloc(rows_A * rows_B * sizeof(double));

        double start_time = omp_get_wtime(); // start timer before distance computation

        // dist[i][j] = |A[i] - B[j]| 
        #pragma omp parallel for collapse(2)
        for(int i = 0; i < rows_A; i++)
        {
                for (int j = 0; j < rows_B; j++)
                {
                        double sum = 0.0;
                        for(int k = 0; k < cols_A; k++)
                        {
                                const double Aik = A[i*cols_A + k]; 
                                const double Bjk = B[j*cols_A + k];
                                const double vec_diff = Aik - Bjk; // difference in vector components A[i][k] - B[j][k]
                                sum += vec_diff*vec_diff;
                        }
                        dist[i*rows_B + j] = sqrt(sum);
                }
        }
        
        // sanity check - check the first and last 10 values of the dist matrix
        // for(int j = 0; j < 10; j++) printf("%10.4f", dist[j]);
        // printf("\n");
        // for(int j = rows_B-10; j < rows_B; j++) printf("%10.4f", dist[rows_A*rows_B + j]);
        // printf("\n");


        // start solving for DP matrix 

        // base case 
        DP[0] = dist[0]; 
        
        // solve first row and first column in parallel
        #pragma omp sections 
        {
        // first column
            #pragma omp section
            {
                for (int i = 1; i < rows_A; i++) DP[i*rows_B] = dist[i*rows_B] + DP[(i-1)*rows_B];
            }

            // first row 
            #pragma omp section
            {
                for (int j = 1; j < rows_B; j++) DP[j] = dist[j] + DP[j-1];
            }

        }

        
        /**
         * Solve for interior values 
         *      DP[i][j] = dist[i][j] + min(DP[i-1][j], DP[i][j-1], DP[i-1][j-1])
         * IDEA - 
         *      each antidiagonal can be parallelized indepedent of each other 
         *      use output block-decomposition to split the DP matrix into BxB blocks
         *      each thread works on a BxB block 
         *      parallelize across anti-diagonals of blocks instead of anti-diagonal of cells
         *      
         */

        // block size should be detemrined by problem size. should not be a constant
        int BLOCKSIZE = 512; // block-decomposition, block size is BxB. 
        if(argc == 4) BLOCKSIZE = atoi(argv[3]);

        // number of blocks along the row of the interior of the DP matrix 
        const int NBR = (rows_A -1 + BLOCKSIZE - 1)/BLOCKSIZE; 
        // number of blocks along the column of the interior of the DP matrix
        const int NBC = (rows_B -1 + BLOCKSIZE - 1)/BLOCKSIZE; 
        // total number of blocks = NBR * NBC
        
        # pragma omp parallel 
        {
            for (int g = 0; g < NBR + NBC - 1; g++) 
            {
                // g is the g'th anti-diagonal of the interior of the DP matrix
                // the anti-diagonal is composed of blocks, not individual cells 
                // there are (NBR + NBC - 1) antidiagonals
                // if each block is indexed by (bi,bj) then bi+bj=g
                // on the g'th antidiagonal: 
                    // the minimum value for bi is max(0, g-NBC+1)
                    // the maximum value for bi is min(g, NBR-1)
                    // and the corresponding value for bj = g - bi
                int bi_min = g - NBC + 1; if (bi_min < 0) bi_min = 0;
                int bi_max = NBR-1;       if (bi_max > g) bi_max = g;

                # pragma omp for
                for (int bi = bi_min; bi <= bi_max; bi++)
                {
                    int bj = g - bi;

                    // convert (bi,bj) into (i,j) indices of the DP matrix
                    int i_min = 1 + bi * BLOCKSIZE;
                    int i_max = i_min + BLOCKSIZE; if (i_max > rows_A) i_max = rows_A;
                    int j_min = 1 + bj * BLOCKSIZE;
                    int j_max = j_min + BLOCKSIZE; if (j_max > rows_B) j_max = rows_B;

                    // updateh DP matrix within the range of (i_min,j_min) --- (i_max,j_max)
                    for (int i = i_min; i < i_max; i++)
                    {
                        for (int j = j_min; j < j_max; j++)
                        {
                            const double a = DP[(i-1)*rows_B + j]; // previous row
                            const double b = DP[(i)*rows_B + j-1]; // previous column
                            const double c = DP[(i-1)*rows_B + j-1]; // diagonal
                            const double best = find_min3(a,b,c);
                            DP[i*rows_B + j] = dist[i*rows_B + j] + best;
                        }
                    }
                }
                
            }
        }

        double end_time = omp_get_wtime();

        printf("The Final Cost is: %f\n", DP[(rows_A-1)*rows_B + rows_B-1]);
        printf("The Total Completion time (ms) is: %f\n",(end_time - start_time) * 1000.0);


        // sanity check - print the first and last 10 values of DP matrix 
        // for(int j = 0; j < 10; j++) printf("%4.4f ", DP[j]);
        // printf("\n");
        // for(int j = rows_B-10; j < rows_B; j++) printf("%4.4f ", DP[rows_A*rows_B + j]);
        // printf("\n");


        free(A); free(B); free(dist); free(DP);
        return 0;
}
