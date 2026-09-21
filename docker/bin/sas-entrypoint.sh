#!/usr/bin/env bash
# Container entrypoint: make sure the /data/sas library tree exists (the volume
# starts empty), then run whatever was asked for. `run-banking` and `sas` are
# on PATH; anything else (bash, ls, ...) is exec'd as-is.
set -euo pipefail

DATA_ROOT="${SAS_DATA_ROOT:-/data/sas}"
for dir in raw raw/banking raw/insurance \
           staging staging/banking staging/insurance \
           curated reports reports/output archive logs golden \
           formats formats/banking formats/insurance formats/common \
           oracle_dw teradata_dw; do
  mkdir -p "$DATA_ROOT/$dir"
done

exec "$@"
