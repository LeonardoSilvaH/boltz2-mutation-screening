#!/usr/bin/env bash
# Run Boltz-2 co-folding over the generated YAMLs, one gene at a time.
#
# Each gene is an independent, restartable unit: before launching, the script
# stages symlinks to only the jobs that have no result yet, so an interrupted run
# picks up where it stopped. Kill it and re-run at any time.
#
#   bash boltz2/run_boltz.sh [-w boltz2_work] [-o boltz2_out] [-g GENE] [-- extra boltz flags]
#
set -uo pipefail

WORK="boltz2_work"
OUT="boltz2_out"
ONLY_GENE=""
DEVICES=1

while getopts "w:o:g:d:h" opt; do
  case "$opt" in
    w) WORK="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    g) ONLY_GENE="$OPTARG" ;;
    d) DEVICES="$OPTARG" ;;
    h) sed -n '2,10p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))
EXTRA=("$@")   # anything after -- goes straight to `boltz predict`

JOBS_DIR="$WORK/jobs"
PENDING_ROOT="$WORK/pending"
LOG_DIR="$WORK/logs"
mkdir -p "$OUT" "$LOG_DIR"

if [ ! -d "$JOBS_DIR" ]; then
  echo "No jobs directory at $JOBS_DIR -- run make_yamls.py first." >&2
  exit 1
fi

# Preflight: a broken install (a torch/torchvision mismatch, say) fails on import
# and would otherwise repeat the same traceback once per gene. Catch it up front.
if ! preflight="$(boltz --help 2>&1)"; then
  echo "ERROR: 'boltz --help' failed, so no gene can run. The install is broken:" >&2
  echo "$preflight" | tail -15 >&2
  exit 1
fi

# The GPU is checked separately. `boltz --help` only proves the imports work; a
# torch built for a newer CUDA than the driver supports gets all the way into the
# first prediction before failing, and would do so once per gene.
gpu_check="$(python3 -c '
import torch
if torch.cuda.is_available():
    print("OK " + torch.cuda.get_device_name(0))
else:
    built = torch.version.cuda or "no CUDA"
    print("FAIL torch %s (built for CUDA %s) cannot use a GPU here" % (torch.__version__, built))
' 2>&1 | tail -1)"
case "$gpu_check" in
  OK*) echo "GPU: ${gpu_check#OK }" ;;
  *)
    echo "ERROR: no usable GPU, so every gene would fail the same way:" >&2
    echo "  $gpu_check" >&2
    echo "Compare the driver's CUDA version in 'nvidia-smi' with the one torch was" >&2
    echo "built for. If the driver is older, install a torch built for it." >&2
    echo "See the Troubleshooting section of the README." >&2
    exit 1
    ;;
esac

# Boltz imports the fused triangle-multiplication kernels during the forward
# pass, not at startup, so a missing cuequivariance shows up only once a
# prediction is already running -- and then for every gene. `pip install boltz`
# does not pull those kernels in, so check here and fall back rather than fail.
want_no_kernels=1
for arg in ${EXTRA[@]+"${EXTRA[@]}"}; do
  case "$arg" in
    --no_kernels|--use_kernels) want_no_kernels=0 ;;
  esac
done
if [ "$want_no_kernels" -eq 1 ]; then
  if python3 -c 'from cuequivariance_torch.primitives.triangle import triangle_multiplicative_update' 2>/dev/null; then
    echo "Kernels: cuequivariance available"
  else
    echo "NOTE: cuequivariance kernels are not installed, so --no_kernels is being"
    echo "      added. Predictions will work but run slower and use more memory."
    echo "      To install them (faster, and safer for the largest proteins):"
    echo "          pip install cuequivariance-torch cuequivariance-ops-torch-cu12"
    EXTRA+=(--no_kernels)
  fi
fi

MAX_CONSECUTIVE_FAILURES=3
consecutive_failures=0

for gene_dir in "$JOBS_DIR"/*/; do
  gene="$(basename "$gene_dir")"
  [ -n "$ONLY_GENE" ] && [ "$gene" != "$ONLY_GENE" ] && continue

  # boltz writes to <out_dir>/boltz_results_<input dir name>/predictions/<job>/
  preds="$OUT/$gene/boltz_results_$gene/predictions"
  pending="$PENDING_ROOT/$gene"
  rm -rf "$pending"
  mkdir -p "$pending"

  total=0
  todo=0
  for yaml in "$gene_dir"*.yaml; do
    [ -e "$yaml" ] || continue
    total=$((total + 1))
    stem="$(basename "$yaml" .yaml)"
    # Done if the affinity json (or, for structure-only runs, a model) exists.
    if [ -f "$preds/$stem/affinity_$stem.json" ] || compgen -G "$preds/$stem/${stem}_model_0.*" > /dev/null; then
      continue
    fi
    ln -s "$(readlink -f "$yaml")" "$pending/$stem.yaml"
    todo=$((todo + 1))
  done

  if [ "$todo" -eq 0 ]; then
    echo "[$gene] $total/$total done, nothing to do"
    rm -rf "$pending"
    continue
  fi

  echo "[$gene] $todo of $total jobs pending -- starting $(date '+%F %T')"
  boltz predict "$pending" \
    --out_dir "$OUT/$gene" \
    --devices "$DEVICES" \
    --accelerator gpu \
    --output_format mmcif \
    "${EXTRA[@]}" \
    2>&1 | tee -a "$LOG_DIR/$gene.log"

  status=${PIPESTATUS[0]}
  rm -rf "$pending"

  if [ "$status" -ne 0 ]; then
    consecutive_failures=$((consecutive_failures + 1))
    echo "[$gene] boltz exited $status -- see $LOG_DIR/$gene.log" >&2
    if [ "$consecutive_failures" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
      echo "Stopping: $consecutive_failures genes in a row failed, so this looks" >&2
      echo "like an environment or hardware problem rather than bad input." >&2
      echo "Fix it and re-run -- finished jobs are skipped automatically." >&2
      exit 1
    fi
    echo "[$gene] continuing to next gene" >&2
  else
    consecutive_failures=0
  fi
done

echo "All genes processed. Collect with: python boltz2/collect_results.py --work $WORK --out $OUT"
