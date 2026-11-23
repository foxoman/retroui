#!/bin/sh
# Strix (github.com/usestrix/strix, Apache-2.0): AI agents that read the kit's
# code, build and run it in a sandbox, and report the security holes they can
# show, each with its proof. What they are asked to look at:
# tools/strix/instructions.md.
#
#   sh tools/strix.sh                 a standard scan of the repository
#   sh tools/strix.sh quick           a quick one (minutes)
#   sh tools/strix.sh deep            a deep one (hours)
#
# Needs Docker running (Strix pulls its sandbox image, ghcr.io/usestrix/
# strix-sandbox, the first time) and an AI service of your own:
#   export STRIX_LLM="provider/model"   # as LiteLLM names it: anthropic/..., openai/..., ollama/...
#   export LLM_API_KEY="..."            # (a local model: LLM_API_BASE as well)
# The report goes to strix_runs/ (left out of git).
set -eu
cd "$(dirname "$0")/.."
mode=${1:-standard}
command -v docker > /dev/null || { echo "strix.sh: Docker is not installed"; exit 1; }
docker info > /dev/null 2>&1 || { echo "strix.sh: Docker is not running"; exit 1; }
[ -n "${STRIX_LLM:-}" ] || { echo "strix.sh: set STRIX_LLM (the model) and LLM_API_KEY"; exit 1; }
if ! command -v strix > /dev/null; then
  if command -v pipx > /dev/null; then pipx install strix-agent
  else python3 -m pip install --user strix-agent; fi
fi
exec strix -n --target ./ --scan-mode "$mode" --scope-mode full \
  --instruction-file tools/strix/instructions.md
