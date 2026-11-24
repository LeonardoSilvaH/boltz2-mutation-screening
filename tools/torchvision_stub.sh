#!/usr/bin/env bash
# Create a stand-in `torchvision` package to put ahead of a broken one on sys.path.
#
# WHY THIS EXISTS
#
# Boltz never calls torchvision. It is pulled in only by
#   pytorch_lightning -> torchmetrics -> torchmetrics.functional.image.*
# which imports assorted names from it, some guarded by `_TORCHVISION_AVAILABLE`
# and some not (`dists.py` imports VGG16_Weights unconditionally, for instance).
#
# If the installed torchvision binary does not match the installed torch, those
# imports die with "RuntimeError: operator torchvision::nms does not exist" and
# take boltz down at startup. When the environment is read-only (someone else
# owns it) or no torchvision has been released for the installed torch, you
# cannot fix that by reinstalling. This stub answers any torchvision import so
# the chain loads and Boltz runs.
#
# It resolves ANY submodule and ANY attribute, rather than a fixed list, because
# which names torchmetrics wants varies by version. Attributes return a
# placeholder that raises if it is ever actually called, so nothing fails
# silently.
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

Boltz does not use torchvision; it is imported only by torchmetrics' image
metrics, which Boltz never constructs. This package satisfies those imports
without a torchvision binary matching the installed torch.

Any submodule (torchvision.models, torchvision.ops, ...) and any attribute
resolves to a placeholder. Calling one raises, so code that genuinely needs
torchvision fails loudly rather than misbehaving quietly.
"""

import sys
import types
from importlib.abc import Loader, MetaPathFinder
from importlib.machinery import ModuleSpec

# Report whatever version pip has recorded, so version checks see something
# consistent with the metadata that is still installed.
try:
    from importlib.metadata import version as _version

    __version__ = _version("torchvision")
except Exception:  # pragma: no cover - metadata missing
    __version__ = "0.0.0+stub"


class _Placeholder:
    """Stands in for any torchvision attribute. Raises only when used."""

    def __init__(self, name: str) -> None:
        self._name = name

    def __getattr__(self, item: str):
        if item.startswith("__") and item.endswith("__"):
            raise AttributeError(item)
        return _Placeholder(f"{self._name}.{item}")

    def __call__(self, *args, **kwargs):
        raise RuntimeError(
            f"torchvision is stubbed out; {self._name} is unavailable. "
            "Install a torchvision matching your torch if you need it."
        )

    def __repr__(self) -> str:
        return f"<torchvision stub {self._name}>"


def _module_getattr(module_name: str):
    def __getattr__(item: str):
        if item.startswith("__") and item.endswith("__"):
            raise AttributeError(item)
        return _Placeholder(f"{module_name}.{item}")

    return __getattr__


class _StubLoader(Loader):
    def create_module(self, spec: ModuleSpec):
        module = types.ModuleType(spec.name)
        module.__path__ = []  # make it a package so submodules resolve
        module.__getattr__ = _module_getattr(spec.name)
        return module

    def exec_module(self, module) -> None:
        pass


class _StubFinder(MetaPathFinder):
    def find_spec(self, fullname: str, path=None, target=None):
        if fullname == "torchvision" or fullname.startswith("torchvision."):
            if fullname == "torchvision":
                return None  # this module itself is already being imported
            return ModuleSpec(fullname, _StubLoader(), is_package=True)
        return None


sys.meta_path.insert(0, _StubFinder())

# Resolve unknown attributes on torchvision itself too.
__getattr__ = _module_getattr("torchvision")
EOF

echo "Stub created at $TARGET."

# Verify: the real test is whether the chain Boltz imports now loads.
export PYTHONPATH="$(cd "$TARGET" && pwd):${PYTHONPATH:-}"

python3 - <<'EOF'
import sys

failures = []

# Shapes torchmetrics is known to use across versions.
checks = [
    "from torchvision import transforms",
    "from torchvision.models import resnet50",
    "from torchvision.models import VGG16_Weights, vgg16",
    "import torchvision.ops",
    "from torchvision.transforms import functional",
]
for stmt in checks:
    try:
        exec(stmt, {})
    except Exception as exc:
        failures.append(f"{stmt!r}: {type(exc).__name__}: {exc}")

if failures:
    print("ERROR: the stub did not satisfy these imports:", file=sys.stderr)
    for line in failures:
        print(f"  - {line}", file=sys.stderr)
    raise SystemExit(1)
print("  basic torchvision imports OK")

# The decisive check, when the real packages are present.
for mod in ("torchmetrics", "pytorch_lightning", "boltz.main"):
    try:
        __import__(mod)
    except ImportError as exc:
        if "torchvision" in str(exc):
            print(f"  {mod}: STILL FAILING on torchvision -- {exc}", file=sys.stderr)
            raise SystemExit(1)
        print(f"  {mod}: not installed here, skipped")
    except Exception as exc:
        print(f"  {mod}: import raised {type(exc).__name__}: {exc}", file=sys.stderr)
        raise SystemExit(1)
    else:
        print(f"  {mod}: imports cleanly")
EOF

cat <<MSG

Verified. Activate it with:
    export PYTHONPATH=$(cd "$TARGET" && pwd):\$PYTHONPATH
    boltz --help

Add the same export to any job script, or compute nodes will not see it.
MSG
