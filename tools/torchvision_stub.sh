#!/usr/bin/env bash
# Create a stand-in `torchvision` package to put ahead of a broken one on sys.path.
#
# WHY THIS EXISTS
#
# Boltz never calls torchvision. It is pulled in only by
#   pytorch_lightning -> torchmetrics -> torchmetrics.functional.image.arniqa
# which does, guarded by `if _TORCHVISION_AVAILABLE:`:
#
#     from torchvision import transforms
#     from torchvision.models import resnet50
#
# If the installed torchvision binary does not match the installed torch, that
# import dies with "RuntimeError: operator torchvision::nms does not exist" and
# takes boltz down at startup. When the environment is read-only (someone else
# owns it) or no torchvision has been released yet for the installed torch, you
# cannot fix it by reinstalling. This stub satisfies those two imports and
# nothing else, so the chain loads and Boltz runs.
#
# This is a workaround, not a fix. Prefer repairing the environment when you can
# -- see the Troubleshooting section of the README.
#
# Usage:
#     bash tools/torchvision_stub.sh [target_dir]      # default: ./torchvision_stub
#     export PYTHONPATH=<target_dir>:$PYTHONPATH
#     boltz --help
#
set -euo pipefail

TARGET="${1:-./torchvision_stub}"
PKG="$TARGET/torchvision"
mkdir -p "$PKG"

cat > "$PKG/__init__.py" <<'EOF'
"""Minimal stand-in for torchvision.

Boltz does not use torchvision. This package exists only so that
torchmetrics' ARNIQA module can import `transforms` and `models.resnet50`
without a torchvision binary matching the installed torch.

Anything that genuinely needs torchvision will fail loudly rather than
silently misbehave.
"""

__version__ = "0.0.0+stub"

from . import models, transforms  # noqa: F401
EOF

cat > "$PKG/transforms.py" <<'EOF'
"""Stubbed out: Boltz does not use torchvision transforms."""
EOF

cat > "$PKG/models.py" <<'EOF'
"""Stubbed out: Boltz does not use torchvision models."""


def resnet50(*args, **kwargs):
    raise RuntimeError("torchvision is stubbed out; resnet50 is unavailable")
EOF

# Verify the stub answers exactly the imports arniqa.py makes.
if PYTHONPATH="$TARGET" python3 -c "
from torchvision import transforms
from torchvision.models import resnet50
" 2>/dev/null; then
  echo "Stub created at $TARGET and verified."
  echo
  echo "Activate it with:"
  echo "    export PYTHONPATH=$(cd "$TARGET" && pwd):\$PYTHONPATH"
  echo "    boltz --help"
  echo
  echo "Add the same export to any job script, or compute nodes will not see it."
else
  echo "ERROR: the stub did not import cleanly. Is another torchvision earlier on sys.path?" >&2
  exit 1
fi
