// cuBLAS GEMM throughput: FP32 and FP16 (FP32 accumulate), 4096^3.
#include <cstdio>
#include <cublas_v2.h>
#include <cuda_fp16.h>
int main() {
  const int n = 4096, R = 20; cublasHandle_t h; cublasCreate(&h);
  void *A, *B, *C; cudaMalloc(&A, 4ull*n*n); cudaMalloc(&B, 4ull*n*n); cudaMalloc(&C, 4ull*n*n);
  cudaMemset(A, 0, 4ull*n*n); cudaMemset(B, 0, 4ull*n*n);
  float one = 1, zero = 0; cudaEvent_t a, b; cudaEventCreate(&a); cudaEventCreate(&b);
  struct { const char* name; cudaDataType t; cublasComputeType_t c; } ts[] = {
    {"FP32", CUDA_R_32F, CUBLAS_COMPUTE_32F}, {"FP16", CUDA_R_16F, CUBLAS_COMPUTE_32F}};
  for (auto& t : ts) {
    auto go = [&] { cublasGemmEx(h, CUBLAS_OP_N, CUBLAS_OP_N, n, n, n, &one, A, t.t, n, B, t.t, n, &zero, C, t.t, n, t.c, CUBLAS_GEMM_DEFAULT); };
    go(); cudaDeviceSynchronize(); cudaEventRecord(a);
    for (int i = 0; i < R; i++) go();
    cudaEventRecord(b); cudaEventSynchronize(b); float ms; cudaEventElapsedTime(&ms, a, b);
    printf("%s GEMM %.2f TFLOPS\n", t.name, 2.0*n*n*n*R / ms / 1e9);
  }
}
