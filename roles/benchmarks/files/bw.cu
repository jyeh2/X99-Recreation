// Host<->device copy bandwidth, pinned and pageable, 256 MiB x 20 reps.
#include <cstdio>
#include <cstdlib>
#include <cuda_runtime.h>
int main() {
  const size_t N = 256ull << 20; const int R = 20;
  void *d, *pin, *pag = malloc(N);
  cudaMalloc(&d, N); cudaMallocHost(&pin, N);
  cudaEvent_t a, b; cudaEventCreate(&a); cudaEventCreate(&b);
  struct { const char* name; void* h; } hs[] = {{"pinned", pin}, {"pageable", pag}};
  for (auto& h : hs) for (int dir = 0; dir < 2; dir++) {
    auto kind = dir ? cudaMemcpyDeviceToHost : cudaMemcpyHostToDevice;
    void *dst = dir ? h.h : d, *src = dir ? d : h.h;
    cudaMemcpy(dst, src, N, kind);  // warmup
    cudaEventRecord(a);
    for (int i = 0; i < R; i++) cudaMemcpy(dst, src, N, kind);
    cudaEventRecord(b); cudaEventSynchronize(b);
    float ms; cudaEventElapsedTime(&ms, a, b);
    printf("%-8s %s %.2f GB/s\n", h.name, dir ? "D2H" : "H2D", (double)N * R / ms / 1e6);
  }
  return 0;
}
