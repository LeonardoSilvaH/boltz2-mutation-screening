# boltz2-mutation-screening

Co-folds cancer-associated protein variants with their candidate drugs using
[Boltz-2](https://github.com/jwohlwend/boltz), and predicts a binding affinity for
every pair, so each mutant can be compared directly against its wild-type counterpart.

**Scale:** 37 genes · 228 structures (191 mutants + 37 wild-type) · 137 unique drugs ·
**5322 protein × ligand jobs.**

## Contents

```
boltz2/                     the pipeline
data/consolidated_projects/ structures and ligands (197 MB)
  <GENE>/<DRUG>.sdf           ligands, shared by every variant of the gene
  <GENE>/wild-type/*.pdb      reference structure
  <GENE>/<VARIANT>/*.pdb      one modelled mutant per directory
  <GENE>/<VARIANT>/ranking_debug.json   AlphaFold per-model pLDDT
```

Protein structures are AlphaFold2 models; mutants were modelled independently of
their wild type, which is why `qc_structures.py` verifies the relationship rather
than assuming it.

## How it works

Boltz-2 folds from *sequence*, not from a supplied structure. The AlphaFold models
are therefore not the input — the sequence read back from their Cα atoms is, and the
mutation travels inside it. The structures are still used: `qc_structures.py` checks
each mutant really is a single substitution of its wild type, and `manifest.tsv`
records which PDB each job came from.

The one thing that makes this tractable is **MSA reuse**. Every chain needs an MSA,
but there are only 37 distinct proteins, and mutants differ by one residue. So the
MSA server is queried once per gene on the wild-type sequence, and each mutant's
`.a3m` is derived by patching the query row — same length, so every alignment column
stays valid. That is 37 searches instead of 5322.

## Requirements

```bash
pip install boltz rdkit pyyaml
```

A CUDA GPU is required in practice. These runs were sized for a single A100.

## Running it

**1. Check the inputs.** Exits non-zero if anything is wrong, so it can gate a run.

```bash
python boltz2/qc_structures.py --root data/consolidated_projects
```

**2. Fetch the MSAs** (network-bound, no GPU, ~37 searches, resumable).

```bash
python boltz2/prepare_msas.py --root data/consolidated_projects --work boltz2_work
```

**3. Generate the YAMLs.** Add `--dry-run` first to see the counts.

```bash
python boltz2/make_yamls.py --root data/consolidated_projects --work boltz2_work
```

**4. Predict.** One gene at a time, restartable — kill it and re-run whenever.

```bash
bash boltz2/run_boltz.sh -w boltz2_work -o boltz2_out
```

Flags after `--` pass straight through to `boltz predict`, e.g.
`bash boltz2/run_boltz.sh -- --diffusion_samples 3 --no_kernels`.

**5. Collect.**

```bash
python boltz2/collect_results.py --work boltz2_work --out boltz2_out
```

`results.csv` has one row per job; `deltas.csv` has one row per (gene, mutant, drug)
with the wild-type subtracted out.

## Reading the numbers

`affinity_pred_value` is **log₁₀(IC50) with IC50 in µM**, so *lower is tighter*, and a
negative `delta_pred` means the mutant is predicted to bind more tightly than the wild
type. `affinity_probability_binary` (0–1) is the better field for "does this bind at
all"; use `affinity_pred_value` to rank molecules already believed active.
`collect_results.py` also reports `affinity_kcal_per_mol` via Boltz's own conversion,
`(6 - y) × 1.364`.

## Generated layout

```
boltz2_work/
  msa/<GENE>__<VARIANT>.a3m
  jobs/<GENE>/<GENE>__<VARIANT>__<DRUG>.yaml
  pending/<GENE>/           staged symlinks, rebuilt each run
  logs/<GENE>.log
  manifest.tsv, results.csv, deltas.csv
boltz2_out/<GENE>/boltz_results_<GENE>/predictions/<JOB>/
```

The job name doubles as the output directory name, which is the only key available
when collecting results — hence `GENE__VARIANT__DRUG` encoded in the filename.

## Things worth knowing before a long run

* **`msa:` paths are resolved against the current working directory**, not against the
  YAML's own directory. `make_yamls.py` writes absolute paths for this reason; if you
  move `boltz2_work`, regenerate the YAMLs.
* **`boltz predict <dir>` is not recursive** and raises `RuntimeError` on any
  subdirectory or non-YAML file in the directory. Keep `jobs/<GENE>/` clean.
* **Affinity takes exactly one ligand**, which must be the binder chain, under 128
  atoms. All 137 drugs here pass, though 261 gene/drug files exceed the 56-atom
  training range and their affinity values should be treated as extrapolation.
* **Memory.** NOTCH1 (2555 aa) and MTOR (2549 aa) are the risk on an 80 GB A100. If
  they OOM, try `--no_kernels`, or exclude them with `--max-length` in `make_yamls.py`
  and run them separately on a trimmed domain.
* **Runtime.** 5322 jobs at a median 781 residues with the affinity head is on the
  order of hundreds of GPU-hours on one A100. Per-gene batching means you can run
  genes across several GPUs by calling `run_boltz.sh -g <GENE>` in parallel.

## Known data issues

`qc_structures.py` currently reports three mutant models that are not clean single
substitutions of their wild type and should be re-modelled before being trusted:

| Variant | Problem |
|---|---|
| `FGFR2/pS252W` | 821 aa vs 820, plus two unexplained changes at 314–315 |
| `KIT/pD816Y` | 869 aa vs 976 — the model is truncated |
| `MYC/pP74A` | 454 aa vs 453 — frame-shifted at the N-terminus |

The pipeline does not silently mis-handle them: each falls back to its own MSA search
instead of sharing the wild-type alignment.

## Running on a remote GPU server

The repository is public, so no credentials are needed to clone it:

```bash
git clone https://github.com/LeonardoSilvaH/boltz2-mutation-screening.git
cd boltz2-mutation-screening
```

That pulls ~200 MB. If you only ever need the current state, `git clone --depth 1`
halves the transfer. To update later, `git pull`; results stay out of the way because
`boltz2_work/` and `boltz2_out/` are gitignored.

Then set up the environment and confirm the GPU is visible:

```bash
conda create -n boltz2 python=3.11 -y && conda activate boltz2
pip install torch --index-url https://download.pytorch.org/whl/cu126   # match nvidia-smi
pip install boltz rdkit pyyaml
python -c "import torch; print(torch.cuda.get_device_name(0))"
```

That last line is the one that matters: it fails if torch was built for a newer
CUDA than the driver provides, which is easy to hit because the default PyPI
wheel tracks the newest CUDA. Check the driver's version with `nvidia-smi` and
pick the matching index.

Boltz downloads its model weights (several GB) into `~/.boltz` on first use. Set
`BOLTZ_CACHE` if the home directory is small or not shared between nodes.

Steps 1–3 need no GPU and can run on the login node; step 4 is the GPU job. Because
`run_boltz.sh` stages only unfinished jobs, it is safe to run it under a scheduler
with a wall-clock limit and simply resubmit until everything is done.

## Troubleshooting

**`RuntimeError: operator torchvision::nms does not exist`** — torchvision's compiled
ops do not match the installed torch. Boltz never calls torchvision itself; it is
dragged in through `pytorch_lightning` → `torchmetrics` → `arniqa`, and torchmetrics
guards that import with `if _TORCHVISION_AVAILABLE:`. So the quickest fix is simply
to remove it:

```bash
pip uninstall -y torchvision
boltz --help
```

This leaves `torch` untouched, which matters because other compiled dependencies
(`cuequivariance`, `trifast`) are built against the installed torch and would need
rebuilding if it moved.

If something else in the environment genuinely needs torchvision, reinstall the
version matching your torch instead — note that importing torchvision is what
crashes, so read the versions from package metadata rather than by importing:

```bash
pip list | grep -Ei "^(torch|torchvision|torchmetrics|pytorch-lightning) "
```

torch 2.x pairs with torchvision 0.(x+15): 2.5→0.20, 2.6→0.21, 2.7→0.22, 2.8→0.23.
Install the match from the CUDA index matching the driver in `nvidia-smi`:

```bash
pip install --force-reinstall torchvision==0.21.0 --index-url https://download.pytorch.org/whl/cu121
```

`run_boltz.sh` runs `boltz --help` before the loop, so a broken install is reported
once rather than once per gene.

**`RuntimeError: The NVIDIA driver on your system is too old (found version 12030)`**
— the installed torch was built against a newer CUDA than the driver supports.
`12030` is the driver's own CUDA version, 12.3. Check both numbers:

```bash
nvidia-smi | head -3
python -c "import torch; print(torch.__version__, torch.version.cuda)"
```

CUDA 12.x builds run on any 12.x driver, but a **CUDA 13 build needs a 13.x
driver** (r580 or newer), so torch 2.15 from the default PyPI index will not run
on a 12.3 driver. Install a torch built for the driver's CUDA instead:

```bash
pip install torch --index-url https://download.pytorch.org/whl/cu126
```

This is the same mismatch behind the torchvision error above, seen from the other
side: an environment pinned to CUDA 12 (`torchvision 0.20.1+cu121`) had torch
upgraded past it. Putting torch back on a CUDA 12 build fixes both at once, and
the stub is then unnecessary — so prefer this to stacking workarounds. Note that
`cuequivariance` and `trifast` are compiled against torch and will need
reinstalling after it moves.

If the environment is not writable, this cannot be fixed in place: a read-only
environment can be worked around for a pure-Python import (the stub above) but
not for a compiled binary. Build your own environment, as described below.

`run_boltz.sh` checks `torch.cuda.is_available()` before the loop, so this is
reported once rather than discovered inside each gene's prediction.

**`PermissionError` when trying to fix the environment** — the conda environment
belongs to another user, so it cannot be repaired in place. Check who owns it and
whether the group write bit is set:

```bash
ls -ld "$(python -c 'import site; print(site.getsitepackages()[0])')"; id
```

If it shows `drwxrwxr-x someone somegroup`, the *group* can write, so an admin
adding you to that group (`sudo usermod -aG somegroup $USER`, then log out and back
in) is a lighter fix than `chown` and makes the environment maintainable again.

Until then, you can keep using that environment and override the one broken package
without writing to it, since Python searches `PYTHONPATH` before site-packages:

```bash
bash tools/torchvision_stub.sh /hd/$USER/torchvision_stub
export PYTHONPATH=/hd/$USER/torchvision_stub:$PYTHONPATH
boltz --help
```

That installs a stand-in which resolves any torchvision submodule and any attribute,
because which names torchmetrics imports varies by version and some of them are not
guarded. Attributes raise if anything ever calls them, so nothing fails silently.
The script verifies itself by importing `torchmetrics`, `pytorch_lightning` and
`boltz.main` before reporting success.

Use this when no released torchvision matches the installed torch — torchvision 0.29
pins `torch==2.14.0`, so torch 2.15 has nothing to pair with yet. Add the `PYTHONPATH`
export to any job script, or compute nodes will not see it.

Alternatively, build your own environment somewhere you own:

```bash
python3 -m venv /hd/$USER/envs/boltz2        # no --system-site-packages
source /hd/$USER/envs/boltz2/bin/activate
pip install torch --index-url https://download.pytorch.org/whl/cu126   # match the driver
pip install boltz rdkit
```

Install torch first, from the CUDA index matching `nvidia-smi`, or pip will pull
the default wheel — which may be built for a CUDA your driver does not support.
Do not pass `--system-site-packages`: inheriting the broken torchvision is exactly
what this avoids. Point the model cache at the same disk if home is small or is not
shared across compute nodes:

```bash
export BOLTZ_CACHE=/hd/$USER/.boltz
```

Add that line to the job script too, so compute nodes see it.

**Every gene fails in a row** — the runner stops after three consecutive failures on
the assumption that the problem is the environment or the GPU rather than the input.
Finished jobs are always skipped, so fix the cause and re-run the same command.

## License

MIT — see [LICENSE](LICENSE). This covers the code and the derived data in this
repository; the upstream tools it calls carry their own licenses, and Boltz-2's
weights in particular have terms of their own.

## Credits

Protein structures predicted with [AlphaFold2](https://github.com/google-deepmind/alphafold)
(Jumper et al., *Nature* 2021). Co-folding and affinity prediction with
[Boltz-2](https://github.com/jwohlwend/boltz). Ligand handling via
[RDKit](https://www.rdkit.org/). MSAs from the
[ColabFold](https://github.com/sokrypton/ColabFold) MMseqs2 server.
