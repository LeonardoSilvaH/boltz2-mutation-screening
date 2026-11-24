#!/usr/bin/env bash
# Build a private Boltz-2 environment with a torch that matches the GPU driver.
#
# WHY THIS EXISTS
#
# `pip install boltz` pulls whatever torch is newest on PyPI, which tracks the
# newest CUDA. On a machine whose driver is older than that CUDA *major*
# version, the install succeeds and then fails at the first prediction with
# "The NVIDIA driver on your system is too old". CUDA 12.x builds run on any
# 12.x driver, but a CUDA 13 build needs a 13.x driver -- that boundary is not
# crossable.
#
# So torch is installed first, explicitly, from the index matching the driver,
# and pinned so that installing boltz cannot quietly replace it.
#
# Usage:
#     bash tools/setup_env.sh [target_dir] [--cuda cu126] [--python /usr/bin/python3.12]
#
# Defaults to ~/envs/boltz2. Pass --cuda to override the detected build.
#
set -euo pipefail

TARGET=""
CUDA_OVERRIDE=""
PYTHON_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --cuda)   CUDA_OVERRIDE="$2"; shift 2 ;;
    --python) PYTHON_OVERRIDE="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *)  TARGET="$1"; shift ;;
  esac
done
TARGET="${TARGET:-$HOME/envs/boltz2}"

say()  { printf '\n== %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 1. location
say "Checking where the environment will go"

if [ -e "$TARGET" ]; then
  die "$TARGET already exists. Remove it or choose another path."
fi

parent="$(dirname "$TARGET")"
mkdir -p "$parent" 2>/dev/null || die "cannot create $parent -- no write permission there."
[ -w "$parent" ] || die "$parent is not writable by $(id -un). Pick a path you own."

avail_kb="$(df -Pk "$parent" | awk 'NR==2 {print $4}')"
avail_gb=$((avail_kb / 1024 / 1024))
echo "   $parent is writable, ${avail_gb} GB free"
if [ "$avail_gb" -lt 12 ]; then
  echo "   WARNING: torch and its CUDA libraries need roughly 8 GB, and Boltz's"
  echo "   weights several more. ${avail_gb} GB may not be enough."
fi

# ------------------------------------------------------------- 2. interpreter
say "Choosing a Python interpreter"

# Deliberately prefer a system python over whatever is on PATH: if a conda
# environment is active, `python3` is that environment's interpreter, and a venv
# built from it keeps depending on it. When the conda environment belongs to
# someone else, that is exactly the dependency this script exists to escape.
in_range() {
  "$1" -c 'import sys; raise SystemExit(0 if (3,10) <= sys.version_info < (3,13) else 1)' 2>/dev/null
}
# `import venv` is not enough: Debian ships the module but splits out ensurepip,
# and without it `python -m venv` fails only after creating the directory.
can_venv() {
  "$1" -c 'import venv, ensurepip' 2>/dev/null
}

pick_python() {
  if [ -n "$PYTHON_OVERRIDE" ]; then echo "$PYTHON_OVERRIDE"; return; fi
  local cand
  for cand in /usr/bin/python3.12 /usr/bin/python3.11 /usr/bin/python3.10 /usr/bin/python3; do
    [ -x "$cand" ] || continue
    if in_range "$cand" && can_venv "$cand"; then echo "$cand"; return; fi
  done
  # No complete system interpreter. A conda python still builds a working venv,
  # so fall back to one rather than stopping -- with a warning, since a venv
  # built from someone else's conda keeps depending on it.
  cand="$(command -v python3 || true)"
  if [ -n "$cand" ] && in_range "$cand" && can_venv "$cand"; then echo "$cand"; return; fi
  echo ""
}

PY="$(pick_python)"
if [ -z "$PY" ] || [ ! -x "$PY" ]; then
  echo "No Python 3.10-3.12 with a working venv module was found." >&2
  echo "Candidates checked:" >&2
  for cand in /usr/bin/python3.12 /usr/bin/python3.11 /usr/bin/python3.10 /usr/bin/python3 "$(command -v python3 || true)"; do
    [ -n "$cand" ] && [ -x "$cand" ] || continue
    v="$("$cand" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo '?')"
    why="ok"
    in_range "$cand"  || why="Python $v is outside 3.10-3.12"
    if [ "$why" = "ok" ] && ! can_venv "$cand"; then why="no ensurepip (apt install python${v}-venv)"; fi
    echo "   $cand: $why" >&2
  done
  die "pass a usable one with --python /path/to/python3."
fi

pyver="$("$PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
in_range "$PY" || die "Python $pyver at $PY is outside Boltz's supported range (3.10-3.12)."
can_venv "$PY" || die "$PY cannot create a venv (missing ensurepip; on Debian/Ubuntu:
       apt install python${pyver}-venv)."

echo "   using $PY (Python $pyver)"
case "$PY" in
  /usr/bin/*) ;;
  *) echo "   NOTE: not a system interpreter. If it belongs to a conda environment"
     echo "   you do not own, this venv will still depend on that installation." ;;
esac

# ---------------------------------------------------------------- 3. the CUDA
say "Matching the CUDA build to the driver"

driver_cuda=""
if command -v nvidia-smi >/dev/null 2>&1; then
  driver_cuda="$(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA Version: *\([0-9][0-9.]*\).*/\1/p' | head -1)"
fi

if [ -n "$CUDA_OVERRIDE" ]; then
  CUDA_TAG="$CUDA_OVERRIDE"
  echo "   driver reports CUDA ${driver_cuda:-unknown}; using $CUDA_TAG (you asked for it)"
elif [ -z "$driver_cuda" ]; then
  die "could not read the driver's CUDA version from nvidia-smi. Run this on the
       GPU node, or pass --cuda cu126 to choose a build yourself."
else
  major="${driver_cuda%%.*}"
  case "$major" in
    # Within a major version CUDA is forward compatible, so a cu126 build is
    # fine on any 12.x driver. Across major versions it is not, which is the
    # whole problem. Candidates are tried newest-first and probed below.
    12) candidates="cu126 cu124 cu121" ;;
    13) candidates="cu130 cu128 cu126" ;;
    *)  die "unexpected driver CUDA version '$driver_cuda'. Pass --cuda yourself." ;;
  esac

  cptag="cp${pyver/./}"

  # Probe each index for a wheel matching this Python. A failed fetch must not
  # be read as "no wheel": that would silently fall through to an older CUDA
  # build, and the older indexes carry much older torch versions. So the three
  # outcomes are kept distinct -- found, absent, unreachable.
  probe() {   # 0 = has a wheel, 1 = no wheel, 2 = could not fetch
    local tag="$1" listing="" attempt
    for attempt in 1 2 3; do
      if listing="$(curl -fsSL --max-time 30 "https://download.pytorch.org/whl/$tag/torch/" 2>/dev/null)"; then
        # Matched in bash rather than by piping to grep: `grep -q` closes the
        # pipe on its first hit, printf dies of SIGPIPE, and under `pipefail`
        # the pipeline then reports failure on a successful match.
        case "$listing" in
          *"-$cptag-"*) return 0 ;;
          *) return 1 ;;
        esac
      fi
      sleep 2
    done
    return 2
  }

  CUDA_TAG=""
  unreachable=0
  for tag in $candidates; do
    # `|| rc=$?` keeps set -e from treating a probe miss as a fatal error.
    rc=0; probe "$tag" || rc=$?
    case "$rc" in
      0) CUDA_TAG="$tag"; break ;;
      1) echo "   $tag has no wheel for $cptag, trying the next" ;;
      2) echo "   could not reach the $tag index"; unreachable=1 ;;
    esac
  done

  if [ -z "$CUDA_TAG" ] && [ "$unreachable" -eq 1 ]; then
    die "could not reach download.pytorch.org to see which builds exist.
       Check the network or a proxy, or choose a build yourself:
           bash $0 $TARGET --cuda cu126"
  fi
  [ -n "$CUDA_TAG" ] || die "no CUDA $major torch wheel found for Python $pyver.
       Check https://pytorch.org/get-started/locally/ and pass --cuda."
  echo "   driver is CUDA $driver_cuda, installing the $CUDA_TAG build"
fi

INDEX="https://download.pytorch.org/whl/$CUDA_TAG"

# ------------------------------------------------------------------- 4. build
say "Creating the virtual environment"
# No --system-site-packages: inheriting a broken torch or torchvision from the
# surrounding environment is precisely what this avoids.
"$PY" -m venv "$TARGET"
# shellcheck disable=SC1091
source "$TARGET/bin/activate"
python -m pip install --quiet --upgrade pip wheel
echo "   $TARGET ready"

say "Installing torch from $INDEX"
python -m pip install --index-url "$INDEX" torch

torch_ver="$(python -c 'import torch; print(torch.__version__)')"
echo "   installed torch $torch_ver"

say "Checking the GPU before going further"
if ! python -c 'import torch, sys; sys.exit(0 if torch.cuda.is_available() else 1)' 2>/dev/null; then
  python -c 'import torch; print(torch.__version__, torch.version.cuda)' || true
  echo
  echo "torch installed, but it still cannot reach the GPU." >&2
  echo "If you are on a login node without a GPU, this is expected -- re-run the" >&2
  echo "check on the GPU node. Otherwise try an older build:" >&2
  echo "    rm -rf $TARGET && bash $0 $TARGET --cuda cu121" >&2
  exit 1
fi
echo "   $(python -c 'import torch; print(torch.cuda.get_device_name(0))')"

# ------------------------------------------------------------------ 5. boltz
say "Installing Boltz and friends"
# Pin torch for the rest of the install. Without this, boltz's own requirements
# can pull a different torch from PyPI -- the default wheel, built for the CUDA
# that does not work here -- silently undoing the step above.
constraints="$TARGET/constraints.txt"
echo "torch==$torch_ver" > "$constraints"
# torchvision is deliberately not installed: Boltz never calls it, and
# torchmetrics skips its image metrics when it is absent.
python -m pip install --constraint "$constraints" boltz rdkit pyyaml

# The fused triangle-multiplication kernels are a separate install that `pip
# install boltz` does not pull in, but Boltz imports them during the forward
# pass unless --no_kernels is passed. The cu12 ops package is the compiled half;
# cuequivariance-torch alone is not enough.
say "Installing the CUDA kernels Boltz uses"
# The ops package is published per CUDA *major* version: cu126 -> cu12.
OPS_TAG="${CUDA_TAG:0:4}"
kernels_ok=1
python -m pip install --constraint "$constraints" \
  cuequivariance-torch "cuequivariance-ops-torch-$OPS_TAG" 2>&1 | tail -5 || kernels_ok=0
if [ "$kernels_ok" -eq 1 ]; then
  python -c 'from cuequivariance_torch.primitives.triangle import triangle_multiplicative_update' \
    2>/dev/null || kernels_ok=0
fi

say "Verifying"
now_ver="$(python -c 'import torch; print(torch.__version__)')"
if [ "$now_ver" != "$torch_ver" ]; then
  die "installing boltz replaced torch ($torch_ver -> $now_ver). Report this;
       the constraints file should have prevented it."
fi
python -c 'import torch, sys; sys.exit(0 if torch.cuda.is_available() else 1)' \
  || die "torch lost access to the GPU after installing boltz."
boltz --help > /dev/null || die "'boltz --help' fails in the new environment."
echo "   torch $now_ver, GPU reachable, boltz imports cleanly"
if [ "$kernels_ok" -eq 1 ]; then
  echo "   cuequivariance kernels available"
else
  echo
  echo "   WARNING: the cuequivariance kernels did not install. Boltz still runs,"
  echo "   but every prediction needs --no_kernels or it will fail in the forward"
  echo "   pass. run_boltz.sh detects this and adds the flag for you; it is slower"
  echo "   and uses more memory, so installing them later is worth it:"
  echo "       pip install --constraint $constraints cuequivariance-torch cuequivariance-ops-torch-$OPS_TAG"
fi

cat <<MSG

Done. Use it with:

    source $TARGET/bin/activate
    export BOLTZ_CACHE=$parent/.boltz

Put both lines in any job script -- compute nodes do not inherit them. The old
PYTHONPATH torchvision stub is not needed here and should not be exported into
this environment; it would shadow nothing and only confuse things.

Then run the pipeline as usual:

    python boltz2/qc_structures.py --root data/consolidated_projects
MSG
