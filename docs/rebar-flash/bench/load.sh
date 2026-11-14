#!/bin/bash
# Cold-load time (model file already in page cache) via Ollama's load_duration. Usage: ./load.sh [model] [runs]
M=${1:-qwen3:8b}; N=${2:-5}
unload() { curl -s localhost:11434/api/generate -d "{\"model\":\"$M\",\"keep_alive\":0}" >/dev/null; sleep 2; }
unload; curl -s localhost:11434/api/generate -d "{\"model\":\"$M\",\"prompt\":\"hi\",\"stream\":false,\"options\":{\"num_predict\":1}}" >/dev/null  # warm page cache
for i in $(seq $N); do
  unload
  curl -s localhost:11434/api/generate -d "{\"model\":\"$M\",\"prompt\":\"hi\",\"stream\":false,\"options\":{\"num_predict\":1}}" \
    | python3 -c "import json,sys; print('%.2f s' % (json.load(sys.stdin)['load_duration']/1e9))"
done
unload
