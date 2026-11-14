#!/bin/bash
# Prompt-processing (unique prefix per run defeats prompt cache) and generation speed (tok/s) via Ollama. Usage: ./llm.sh [model] [runs]
M=${1:-qwen3:8b}; N=${2:-3}
P0=$(python3 -c "print('Summarize the history of the transistor in detail. ' * 150)")
for i in $(seq $N); do P="Run $RANDOM$RANDOM. $P0"
  curl -s localhost:11434/api/generate -d "$(python3 -c "import json,sys; print(json.dumps({'model':'$M','prompt':sys.argv[1],'stream':False,'think':False,'options':{'num_predict':128,'num_ctx':4096,'seed':1}}))" "$P")" \
    | python3 -c "import json,sys; r=json.load(sys.stdin); print('prompt %.0f tok/s (%d tok) | gen %.1f tok/s' % (r['prompt_eval_count']/r['prompt_eval_duration']*1e9, r['prompt_eval_count'], r['eval_count']/r['eval_duration']*1e9))"
done
