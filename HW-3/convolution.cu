#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <cuda_runtime.h>

#define CUDA_CHECK(call)                                                      \
    do {                                                                      \
        cudaError_t err__ = (call);                                           \
        if (err__ != cudaSuccess) {                                           \
            fprintf(stderr, "CUDA error %s:%d: %s\n",                         \
                    __FILE__, __LINE__, cudaGetErrorString(err__));           \
            exit(EXIT_FAILURE);                                               \
        }                                                                     \
    } while (0)


#define FILTER_RADIUS 8
#define FILTER_DIAM   (2 * FILTER_RADIUS + 1)

#define IN_TILE_DIM   32
#define OUT_TILE_DIM  (IN_TILE_DIM - 2 * FILTER_RADIUS)

#define TILE_DIM      32

#define OPT_BLOCK_W   16
#define OPT_BLOCK_H   16
#define OPT_COARSEN_X 4
#define OPT_COARSEN_Y 4

// Tile size including halo
#define OPT_TILE_W (OPT_BLOCK_W * OPT_COARSEN_X + 2 * FILTER_RADIUS)
#define OPT_TILE_H (OPT_BLOCK_H * OPT_COARSEN_Y + 2 * FILTER_RADIUS)

__constant__ float d_F[FILTER_DIAM * FILTER_DIAM];

__global__
void function_a(const float *N, float *P, int width, int height)
{
    int col = blockIdx.x * blockDim.x + threadIdx.x;
    int row = blockIdx.y * blockDim.y + threadIdx.y;

    if (row >= height || col >= width) return;

    float sum = 0.0f;

    for (int fr = 0; fr < FILTER_DIAM; fr++) {
        for (int fc = 0; fc < FILTER_DIAM; fc++) {
            int r = row - FILTER_RADIUS + fr;
            int c = col - FILTER_RADIUS + fc;

            if (r >= 0 && r < height && c >= 0 && c < width)
                sum += d_F[fr * FILTER_DIAM + fc] * N[r * width + c];
        }
    }

    P[row * width + col] = sum;
}

__global__
void function_b(const float *N, float *P, int width, int height)
{
    __shared__ float tile[IN_TILE_DIM][IN_TILE_DIM];

    int global_col = blockIdx.x * OUT_TILE_DIM + threadIdx.x - FILTER_RADIUS;
    int global_row = blockIdx.y * OUT_TILE_DIM + threadIdx.y - FILTER_RADIUS;

    if (global_row >= 0 && global_row < height &&
        global_col >= 0 && global_col < width)
        tile[threadIdx.y][threadIdx.x] =
            N[global_row * width + global_col];
    else
        tile[threadIdx.y][threadIdx.x] = 0.0f;

    __syncthreads();

    int tCol = threadIdx.x - FILTER_RADIUS;
    int tRow = threadIdx.y - FILTER_RADIUS;

    if (tCol >= 0 && tCol < OUT_TILE_DIM &&
        tRow >= 0 && tRow < OUT_TILE_DIM &&
        global_row >= 0 && global_row < height &&
        global_col >= 0 && global_col < width)
    {
        float sum = 0.0f;

        for (int fr = 0; fr < FILTER_DIAM; fr++)
            for (int fc = 0; fc < FILTER_DIAM; fc++)
                sum += d_F[fr*FILTER_DIAM + fc] *
                       tile[tRow + fr][tCol + fc];

        P[global_row * width + global_col] = sum;
    }
}

__global__
void function_c(const float *N, float *P, int width, int height)
{
    __shared__ float tile[TILE_DIM][TILE_DIM];

    int col = blockIdx.x * TILE_DIM + threadIdx.x;
    int row = blockIdx.y * TILE_DIM + threadIdx.y;

    if (row < height && col < width)
        tile[threadIdx.y][threadIdx.x] = N[row * width + col];
    else
        tile[threadIdx.y][threadIdx.x] = 0.0f;

    __syncthreads();

    if (row >= height || col >= width) return;

    float sum = 0.0f;

    for (int fr = 0; fr < FILTER_DIAM; fr++) {
        for (int fc = 0; fc < FILTER_DIAM; fc++) {

            int r = row - FILTER_RADIUS + fr;
            int c = col - FILTER_RADIUS + fc;

            float val = 0.0f;

            int sRow = threadIdx.y - FILTER_RADIUS + fr;
            int sCol = threadIdx.x - FILTER_RADIUS + fc;

            if (sRow >= 0 && sRow < TILE_DIM &&
                sCol >= 0 && sCol < TILE_DIM)
                val = tile[sRow][sCol];
            else if (r >= 0 && r < height && c >= 0 && c < width)
                val = N[r * width + c];

            if (r >= 0 && r < height && c >= 0 && c < width)
                sum += d_F[fr * FILTER_DIAM + fc] * val;
        }
    }

    P[row * width + col] = sum;
}


__global__
void function_d(const float *N, float *P, int width, int height)
{
    __shared__ float tile[OPT_TILE_H][OPT_TILE_W];

    int tx = threadIdx.x;
    int ty = threadIdx.y;

    int out_x_base = blockIdx.x * (OPT_BLOCK_W * OPT_COARSEN_X);
    int out_y_base = blockIdx.y * (OPT_BLOCK_H * OPT_COARSEN_Y);


    int tile_y;
    for (tile_y = ty; tile_y < OPT_TILE_H; tile_y += OPT_BLOCK_H) {

        int in_y = out_y_base + tile_y - FILTER_RADIUS;
        int y_in = (in_y >= 0 && in_y < height);

        int tile_x;
        for (tile_x = tx; tile_x < OPT_TILE_W; tile_x += OPT_BLOCK_W) {

            int in_x = out_x_base + tile_x - FILTER_RADIUS;

            float val = 0.0f;
            if (y_in && in_x >= 0 && in_x < width)
                val = N[in_y * width + in_x];

            tile[tile_y][tile_x] = val;
        }
    }

    __syncthreads();

    int out_local_y0 = ty * OPT_COARSEN_Y;
    int out_local_x0 = tx * OPT_COARSEN_X;

    int oy;
    for (oy = 0; oy < OPT_COARSEN_Y; oy++) {

        int out_y = out_y_base + out_local_y0 + oy;
        if (out_y >= height) continue;

        int tile_y0 = out_local_y0 + oy;

        int ox;
        for (ox = 0; ox < OPT_COARSEN_X; ox++) {

            int out_x = out_x_base + out_local_x0 + ox;
            if (out_x >= width) continue;

            int tile_x0 = out_local_x0 + ox;

            float sum = 0.0f;

            int ky;
            for (ky = 0; ky < FILTER_DIAM; ky++) {

                int ty_idx = tile_y0 + ky;

                int kx;
                for (kx = 0; kx < FILTER_DIAM; kx++) {
                    int tx_idx = tile_x0 + kx;

                    sum += d_F[ky * FILTER_DIAM + kx] *
                           tile[ty_idx][tx_idx];
                }
            }

            P[out_y * width + out_x] = sum;
        }
    }
}

typedef void (*kernel_ptr)(const float*, float*, int, int);

float benchmark_kernel(const char* label,
                       kernel_ptr kernel,
                       dim3 grid, dim3 block,
                       const float* d_N, float* d_P,
                       int width, int height,
                       int warmup_iters,
                       int timed_iters)
{
    cudaEvent_t start, stop;
    float total_ms = 0.0f;
    int i;

    for (i = 0; i < warmup_iters; i++)
        kernel<<<grid, block>>>(d_N, d_P, width, height);

    CUDA_CHECK(cudaDeviceSynchronize());

    CUDA_CHECK(cudaEventCreate(&start));
    CUDA_CHECK(cudaEventCreate(&stop));

    CUDA_CHECK(cudaEventRecord(start));
    for (i = 0; i < timed_iters; i++)
        kernel<<<grid, block>>>(d_N, d_P, width, height);
    CUDA_CHECK(cudaEventRecord(stop));

    CUDA_CHECK(cudaEventSynchronize(stop));
    CUDA_CHECK(cudaEventElapsedTime(&total_ms, start, stop));

    CUDA_CHECK(cudaEventDestroy(start));
    CUDA_CHECK(cudaEventDestroy(stop));

    total_ms /= timed_iters;

    printf("%s: %.3f ms\n", label, total_ms);
    return total_ms;
}

float max_abs_diff(const float* a, const float* b, size_t n)
{
    float max_err = 0.0f;
    for (size_t i = 0; i < n; i++) {
        if (!isfinite(a[i]) || !isfinite(b[i]))
            return INFINITY;
        float d = fabsf(a[i] - b[i]);
        if (d > max_err)
            max_err = d;
    }
    return max_err;
}

void upload_filter_to_constant(const float *h_F)
{
    CUDA_CHECK(cudaMemcpyToSymbol(
        d_F, h_F, FILTER_DIAM * FILTER_DIAM * sizeof(float)));
}


int main(void)
{
    const int width  = 2048*2;
    const int height = 2048*2;
    const size_t Npix = (size_t)width * height;

    printf("Image %dx%d  |  Filter %dx%d\n\n",
           width, height, FILTER_DIAM, FILTER_DIAM);

    float *h_N     = (float*)malloc(Npix * sizeof(float));
    float *h_ref   = (float*)malloc(Npix * sizeof(float));
    float *h_tmp   = (float*)malloc(Npix * sizeof(float));
    float *h_F     = (float*)malloc(FILTER_DIAM * FILTER_DIAM * sizeof(float));

    if (!h_N || !h_ref || !h_tmp || !h_F) {
        printf("Host allocation failed.\n");
        return 1;
    }

    for (size_t i = 0; i < Npix; i++)
        h_N[i] = (float)rand() / RAND_MAX;

    for (int i = 0; i < FILTER_DIAM * FILTER_DIAM; i++)
        h_F[i] = 1.0f / (FILTER_DIAM * FILTER_DIAM);

    upload_filter_to_constant(h_F);

    float *d_N, *d_P;
    CUDA_CHECK(cudaMalloc(&d_N, Npix * sizeof(float)));
    CUDA_CHECK(cudaMalloc(&d_P, Npix * sizeof(float)));
    CUDA_CHECK(cudaMemcpy(d_N, h_N, Npix * sizeof(float),
                          cudaMemcpyHostToDevice));

    // Keep the reference launch fixed while students vary the benchmark block.
    dim3 ref_block(32, 32);
    dim3 ref_grid((width + 31) / 32, (height + 31) / 32);
    CUDA_CHECK(cudaMemset(d_P, 0xff, Npix * sizeof(float)));
    function_a<<<ref_grid, ref_block>>>(d_N, d_P, width, height);
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaDeviceSynchronize());
    CUDA_CHECK(cudaMemcpy(h_ref, d_P, Npix * sizeof(float),
                          cudaMemcpyDeviceToHost));

    {
        dim3 block(32, 32);
        dim3 grid((width + block.x - 1) / block.x,
                  (height + block.y - 1) / block.y);

        benchmark_kernel("function_a",
                         function_a,
                         grid, block,
                         d_N, d_P,
                         width, height,
                         3, 20);

        printf("Reference output stored.\n\n");
    }

    {
        dim3 block(IN_TILE_DIM, IN_TILE_DIM);
        dim3 grid((width + OUT_TILE_DIM - 1) / OUT_TILE_DIM,
                  (height + OUT_TILE_DIM - 1) / OUT_TILE_DIM);

        benchmark_kernel("function_b",
                         function_b,
                         grid, block,
                         d_N, d_P,
                         width, height,
                         3, 20);

        CUDA_CHECK(cudaMemcpy(h_tmp, d_P,
                              Npix * sizeof(float),
                              cudaMemcpyDeviceToHost));

        printf("   diff vs reference: %e\n\n",
               max_abs_diff(h_ref, h_tmp, Npix));
    }

    {
        dim3 block(TILE_DIM, TILE_DIM);
        dim3 grid((width + TILE_DIM - 1) / TILE_DIM,
                  (height + TILE_DIM - 1) / TILE_DIM);

        benchmark_kernel("function_c",
                         function_c,
                         grid, block,
                         d_N, d_P,
                         width, height,
                         3, 20);

        CUDA_CHECK(cudaMemcpy(h_tmp, d_P,
                              Npix * sizeof(float),
                              cudaMemcpyDeviceToHost));

        printf("   diff vs reference: %e\n\n",
               max_abs_diff(h_ref, h_tmp, Npix));
    }

    {
        dim3 block(OPT_BLOCK_W, OPT_BLOCK_H);
        dim3 grid((width  + OPT_BLOCK_W * OPT_COARSEN_X - 1) /
                (OPT_BLOCK_W * OPT_COARSEN_X),
                (height + OPT_BLOCK_H * OPT_COARSEN_Y - 1) /
                (OPT_BLOCK_H * OPT_COARSEN_Y));

        benchmark_kernel("function_d",
                        function_d,
                        grid, block,
                        d_N, d_P,
                        width, height,
                        3, 20);

        CUDA_CHECK(cudaMemcpy(h_tmp, d_P,
                            Npix * sizeof(float),
                            cudaMemcpyDeviceToHost));

        printf("   diff vs reference: %e\n\n",
            max_abs_diff(h_ref, h_tmp, Npix));
    }


    CUDA_CHECK(cudaFree(d_N));
    CUDA_CHECK(cudaFree(d_P));
    free(h_N);
    free(h_ref);
    free(h_tmp);
    free(h_F);

    CUDA_CHECK(cudaDeviceReset());
    return 0;
}
