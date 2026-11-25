#!/usr/bin/env bash
# Runs INSIDE container 101 (llm-radeon, Ubuntu 24.04). pve-first-boot.sh pushes and runs it.
# ROCm 6.3.3 userspace (the last release with gfx906 rocBLAS kernels) + llama.cpp built for the Radeon VII.
# No kernel driver here: the container uses the host's amdgpu through /dev/kfd and the Radeon's /dev/dri/renderD* node.
set -euo pipefail
VER=6.3.3
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y curl gpg ca-certificates git cmake build-essential pkg-config libcurl4-openssl-dev

if [ ! -f /etc/apt/sources.list.d/rocm.list ]; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/rocm.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/$VER noble main" \
    > /etc/apt/sources.list.d/rocm.list
  printf 'Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 600\n' > /etc/apt/preferences.d/rocm-pin-600
  apt-get update
fi
apt-get install -y rocm-hip-sdk rocminfo rocm-smi-lib
echo /opt/rocm/lib > /etc/ld.so.conf.d/rocm.conf && ldconfig

echo "== GPU check =="
/opt/rocm/bin/rocminfo | grep -m1 -E 'gfx906' || { echo "rocminfo doesn't see gfx906: check /dev/kfd and /dev/dri in the container"; exit 1; }

echo "== llama.cpp (HIP, gfx906, RPC client enabled) =="
# Pinned: llama.cpp RPC only works when both ends run the same commit, and the CMP container must
# build this same one. f498f86 is what kabangy's Ubuntu pooled Radeon + CMP on (2026-11-18).
LLAMA_COMMIT="${LLAMA_COMMIT:-f498f864fbc0472004ee1c3616c1188c68eb157f}"
if [ ! -d /opt/llama.cpp/.git ]; then
  git init -q /opt/llama.cpp
  git -C /opt/llama.cpp remote add origin https://github.com/ggml-org/llama.cpp
fi
cd /opt/llama.cpp
git fetch -q --depth 1 origin "$LLAMA_COMMIT"
git checkout -q --force FETCH_HEAD
HIPCXX="$(/opt/rocm/bin/hipconfig -l)/clang" HIP_PATH="$(/opt/rocm/bin/hipconfig -R)" \
  cmake -S . -B build -DGGML_HIP=ON -DGPU_TARGETS=gfx906 -DGGML_RPC=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"
./build/bin/llama-cli --list-devices

# Test on the Radeon alone with the 4B (fits fully). Don't partially offload the 32B here: the CPU
# layers would need ~6 GB of RAM and this container has 5 GB. The 32B is for pooling with llm-cmp.
# -lm dio: mmap loading thrashes when a model is bigger than RAM (the page cache counts against the
# container's memory limit), so always use direct I/O for big models.
M=$(ls /models/qwen3-4b/*.gguf 2>/dev/null | head -1 || true)
echo
if [ -n "$M" ]; then
  echo "== quick benchmark, $M on the Radeon alone =="
  ./build/bin/llama-bench -m "$M" -ngl 99 -fa 1 -lm dio -p 512 -n 128 -r 3
else
  echo "No model in /models yet (pve-migrate-from-nvme.sh puts it there). To test now, download a small one:"
  echo "  mkdir -p /root/models && curl -L -o /root/models/qwen3-4b.gguf https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf"
  echo "  /opt/llama.cpp/build/bin/llama-bench -m /root/models/qwen3-4b.gguf -ngl 99 -lm dio"
fi
echo
echo "Pooled with llm-cmp later (CMP listed first, 4/20 = Radeon full; use 5,19 in llama-server for 8k ctx):"
echo "  ./build/bin/llama-bench -m /models/qwen3-32b/Qwen3-32B-Q4_K_M.gguf --rpc 10.10.10.12:50052 -ngl 99 -fa 1 -lm dio -ts 4/20"
