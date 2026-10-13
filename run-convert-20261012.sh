#!/usr/bin/env bash
# GLM-5.3 lossless8 target + FP8 drafter conversion — knapcio docs/weights.md recipe,
# adapted: our checkpoints live under /var/tmp/models instead of $HOME/models.
# Offline CPU-only, network-disabled, 16g-capped. Fresh output dirs required (scripts refuse existing).
set -euo pipefail
cd "$(dirname "$0")"

docker run --name glm53-convert-lvkp-20261012 --network none --memory 16g --cpus 4 \
  --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PWD:/recipe:ro" -v "/var/tmp/models:/models" \
  --entrypoint bash glm53-roce:v11-b58f34ea -c '
    set -e
    bash /recipe/scripts/build_lossless8.sh /models/GLM-5.3-Flash-NVFP4-nvidia /models/glm-quant-mix
    python3 /recipe/scripts/drafter_fp8.py /models/GLM-5.3-Flash-DFlash2 /models/GLM-5.3-Flash-DFlash2-fp8blk
    echo CONVERT_ALL_DONE
  '