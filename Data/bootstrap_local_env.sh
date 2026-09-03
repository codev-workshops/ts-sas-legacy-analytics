#!/usr/bin/env bash
# Materialise the directory layout the legacy banking programs expect.
#
# The programs %include macros from /opt/sas/custom/macros and write to
# libraries under /data/sas. Rather than edit the legacy code (it is the
# migration source of truth), this script recreates those paths from the
# repo: /opt/sas/custom/{macros,programs} are symlinks back to Macro/ and
# Programs/, and the /data/sas tree is created empty for the librefs in
# Config/autoexec_local.sas.
#
#   ./Data/bootstrap_local_env.sh          # create paths, then load seed data if SAS is installed
#   SAS_DATA_ROOT=~/sasdata ./Data/bootstrap_local_env.sh
#
# Re-runnable: existing links and directories are left alone.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_ROOT="${SAS_DATA_ROOT:-/data/sas}"
SAS_HOME_DIR="${SAS_CUSTOM_ROOT:-/opt/sas/custom}"

# Creating /data/sas and /opt/sas normally needs root; anything under $HOME does not.
SUDO=""
if ! mkdir -p "$DATA_ROOT" 2>/dev/null || ! mkdir -p "$SAS_HOME_DIR" 2>/dev/null; then
  SUDO="sudo"
fi

echo "Repo root : $REPO_ROOT"
echo "Data root : $DATA_ROOT"
echo "SAS custom: $SAS_HOME_DIR"

# --- /data/sas library tree -------------------------------------------------
for dir in raw raw/banking raw/insurance \
           staging staging/banking staging/insurance \
           curated reports reports/output archive logs \
           formats formats/banking formats/insurance formats/common \
           oracle_dw teradata_dw; do
  $SUDO mkdir -p "$DATA_ROOT/$dir"
done
$SUDO chown -R "$(id -u):$(id -g)" "$DATA_ROOT"

# --- /opt/sas/custom paths referenced by %include ---------------------------
$SUDO mkdir -p "$SAS_HOME_DIR"
[ -e "$SAS_HOME_DIR/macros" ]   || $SUDO ln -s "$REPO_ROOT/Macro" "$SAS_HOME_DIR/macros"
[ -e "$SAS_HOME_DIR/programs" ] || $SUDO ln -s "$REPO_ROOT/Programs" "$SAS_HOME_DIR/programs"

echo "Directory layout ready."

# --- Load the seed data -----------------------------------------------------
if command -v sas >/dev/null 2>&1; then
  echo "Loading seed data with $(command -v sas)..."
  sas -nodms -noterminal \
      -autoexec "$REPO_ROOT/Config/autoexec_local.sas" \
      -set SAS_REPO_ROOT "$REPO_ROOT" \
      -set SAS_DATA_ROOT "$DATA_ROOT" \
      -sysin "$REPO_ROOT/Data/run_local_banking.sas" \
      -log "$DATA_ROOT/logs/run_local_banking.log" \
      -print "$DATA_ROOT/logs/run_local_banking.lst"
  echo "Done. Log: $DATA_ROOT/logs/run_local_banking.log"
else
  echo "No 'sas' executable on PATH — directory layout created, seed data not loaded."
  echo "Run this once SAS is available, or submit Data/run_local_banking.sas from"
  echo "SAS Studio / SAS OnDemand with SAS_REPO_ROOT set to $REPO_ROOT."
fi
