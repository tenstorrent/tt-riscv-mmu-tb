# tt-riscv-mmu-tb regression

Runs the MMU TB test matrix via `runreg.py`. The TB is Makefile-based
(`make compile` / `make run`), so the regression is expressed as generic
`command:`/`deps:` targets: one **build** per simulator and one **test** per
`(sim, test, seed)`, with each test depending on its build.

## Files
| File | Purpose |
|------|---------|
| `runreg.py`          | **Everything**: generates a `regression.yaml` and/or runs one |
| `regression.yaml`    | Default generated regression (2 sims × 4 tests × 3 seeds) |
| `nightly.yaml`       | Larger random-seed regression (2 sims × 4 tests × 10 seeds) |
| `mmu_smoke.yaml`     | Small checked-in smoke regression (2 tests, 1 seed) |
| `excluded_hosts.txt` | Farm nodes to keep out of dispatch |

### One script does everything
`runreg.py` is a single self-contained script (Python 3.6+, stdlib only, no
proprietary dependencies) that both **generates** regressions and **executes**
the target DAG — locally or through any submit wrapper:

```bash
regress/runreg.py                            # generate only
regress/runreg.py --random -n 10             # 10 random seeds per test
regress/runreg.py --run -j 8                 # generate, then run
regress/runreg.py regress/nightly.yaml -j 8  # run an EXISTING yaml (positional)
regress/runreg.py --clean --keep 2           # housekeeping
```

Because generation and execution live in one tool, execution flags are
first-class — no argument-forwarding string:
```bash
regress/runreg.py --random -n 10 --run -j 8 --submit 'bsub -q <queue> -I'
regress/runreg.py regress/regression.yaml --only 'test_vcs_*' -j 8
```

## Quick start
Generation and running are separate steps, so you can inspect/commit a yaml
before spending farm time. Use `--run` to do both in one shot.

```bash
# --- generate only (default) ---------------------------------------------
regress/runreg.py --sims vcs --seeds 3
#   -> writes regress/regression.yaml and prints how to run it

# --- then run it ----------------------------------------------------------
regress/runreg.py regress/regression.yaml -j 8            # portable launcher

# --- or generate AND run in one command ----------------------------------
regress/runreg.py --random -n 10 --run -j 8 --submit 'bsub -q <queue> -I'

# smoke (small, fast):
regress/runreg.py regress/mmu_smoke.yaml
```

### Generate-only vs generate-and-run
| Mode | Command | When |
|------|---------|------|
| Generate only (default) | `runreg.py ...` | inspect/commit the yaml, reuse it later, reproduce a seed set |
| Run an existing yaml | `runreg.py <file.yaml> ...` | re-run a committed regression |
| Generate **and** run | `runreg.py ... --run` | one-shot nightly/soak; no intermediate step |

Execution flags are first-class, so they combine freely with generation flags:
```bash
regress/runreg.py --random -n 10 --run -j 8 --submit 'bsub -q <queue> -I'
regress/runreg.py --run --only 'test_vcs_*' --dry-run
regress/runreg.py --run --skip 'build_*' -j 4      # simv already built
```
The exit status is non-zero if any target failed or was skipped, so
`runreg.py --run` is CI-safe.

## Running a regression
Self-contained DAG runner — Python 3.6+, no proprietary tooling and no
LSF required. PyYAML is used when installed, otherwise a built-in minimal
parser handles the generated yaml. Safe to open source.

```bash
regress/runreg.py regress/regression.yaml            # run all, -j = ncpus
regress/runreg.py regress/regression.yaml -j 8       # concurrency
regress/runreg.py regress/regression.yaml --dry-run  # show DAG, run nothing
regress/runreg.py regress/regression.yaml -v         # echo each command

# filter (deps are pulled in automatically)
regress/runreg.py regress/regression.yaml --only 'test_*ifu*'
regress/runreg.py regress/regression.yaml --skip 'test_*tlb_inv*'

# farm out each target through any submit wrapper (blocking form)
regress/runreg.py regress/regression.yaml --submit 'bsub -q myqueue -K'
regress/runreg.py regress/regression.yaml --submit 'srun -p mypart'
```

Behaviour:
- Targets run once **all deps succeed**; a target whose dep failed is `SKIP`
  (unless `ignore_failed_deps: true`).
- Dependency cycles are detected and reported before anything runs.
- Per-target logs: `regressions/<timestamp>/<target>.log` (override with `-o`).
- Prints a pass/fail/skip summary table and the log path of each failure.
- **Exit code 0 only if everything passed** (non-zero on any fail/skip), so it
  drops straight into CI.

### Build locally, run tests on the farm
When `--submit` is given, targets matching `--local` run on **this host** while
everything else is dispatched. It defaults to `build_*`, which is what you want
here: the build needs `lz4frame.h` (present locally, missing on some farm
nodes), while tests only need the prebuilt `simv`.

```bash
regress/runreg.py regress/regression.yaml -j 8 --submit 'bsub -q <queue> -I'
#   build_mmu_tb_vcs        [local]
#   test_vcs_mmu_ifu_test_s1 [farm]
```
Use `bsub -I`, **not** `-K`: with `-K` the job's output goes to LSF mail and the
per-target log captures only "Job submitted / Job finished". `-I` streams
stdout/stderr back so failures are visible in the log.

### Excluding bad farm nodes
Some nodes lack required runtimes and fail every test. Hosts listed in
`excluded_hosts.txt` (one per line, `#` comments) are automatically turned into
an LSF resource requirement:

```
-R "select[hname!='node01' && hname!='node02']"
```
Note `bsub -m "all ~host"` is **not** accepted by this LSF config; the portable
`select[hname!=...]` form is used instead.

```bash
# add hosts permanently: edit regress/excluded_hosts.txt
# or ad hoc:
regress/runreg.py regress/regression.yaml --submit 'bsub -q <queue> -I' \
    --exclude-host node03 --exclude-host node04
# use a different list / disable:
regress/runreg.py ... --exclude-file my_hosts.txt
regress/runreg.py ... --exclude-file ''
```

The launcher prints the effective routing before running:
```
submit     : bsub -q <queue> -I -R "select[hname!='node01' && ...]"
local-only : build_*
excluded   : node01, node02
```

### Options
| Option | Meaning |
|--------|---------|
| `-j, --jobs N`        | max targets run concurrently (default: CPU count) |
| `-o, --outdir D`      | log directory (default `regressions/<timestamp>`) |
| `--submit 'CMD'`      | prefix every target command with a submit wrapper |
| `--local GLOB`        | run matching targets locally despite `--submit` (default `build_*`; `--local ''` disables) |
| `--exclude-host HOST` | exclude an LSF host (repeatable) |
| `--exclude-file FILE` | host exclusion list (default `regress/excluded_hosts.txt`) |
| `--only GLOB`         | run only matching targets (repeatable; deps auto-included) |
| `--skip GLOB`         | skip matching targets (repeatable) |
| `--clean`             | delete regression logs + per-test run dirs, then exit |
| `--keep N`            | with `--clean`, keep the N most recent regression dirs |
| `--dry-run`           | resolve and print the DAG without executing (with `--clean`, list what would be removed) |
| `-v, --verbose`       | echo each command as it runs |

## Cleaning regression output
```bash
regress/runreg.py --clean --dry-run   # preview what would be removed
regress/runreg.py --clean             # remove all regression output
regress/runreg.py --clean --keep 2    # keep the 2 newest regression dirs
```
`--clean` needs no yaml. It removes:
- `regressions/<timestamp>/` — launcher per-target logs
- `build/<test>_seed<n>/` — per-run `run.log`, waveforms, generated PT JSON

It **keeps** `build/simv`, `build/lib/` (staged libpython) and the other compile
artefacts, so you can re-run immediately via `run-only` with no rebuild. Use
`make clean` instead if you want to wipe the whole build and force a recompile.

## Farm node requirements
Tests need, on the exec node: a Python 3.11 install (stdlib) and
`libpython3.11.so.1.0`. `make run-only` depends on `stage-pylib`, which copies
`libpython3.11.so.1.0` into `build/lib/` (shared storage) and prepends it to
`LD_LIBRARY_PATH` — this fixes nodes missing only the shared library. Nodes
missing the **whole** Python install still fail (`ModuleNotFoundError: No module
named 'encodings'`) and must be added to `excluded_hosts.txt`.

## Generating the matrix
```bash
regress/runreg.py \
    --sims vcs \
    --tests mmu_ifu_test mmu_lsu_test mmu_ifu_lsu_test mmu_tlb_inv_test \
    --seeds 5 --seed0 1 \
    --out regress/nightly.yaml
```
- `--sims`     simulators to build/run (default `vcs verilator`).
- `--tests`    UVM tests (default: all in the `TESTS` map in the script).
- `--seeds, -n`  number of runs (seeds) per test.
- `--seed0`    first seed in sequential mode (default `1`).
- `--random`   use random unique seeds instead of sequential.
- `--master-seed N`  make `--random` reproducible.
- `--arch-cov` build/run with `ARCH_COV=1` (linked corearchcoverage).

### Random seeds
By default seeds are sequential (`seed0, seed0+1, …`) — good for a deterministic
smoke test. For regressions where you want seed diversity, use `--random` and
just say how many runs you want per test:

```bash
# 10 random-seed runs of every test, on both simulators
regress/runreg.py --random -n 10 --out regress/nightly.yaml

# 25 random runs of one test, vcs only
regress/runreg.py --random -n 25 --tests mmu_ifu_test --sims vcs \
    --out regress/ifu_soak.yaml
```
Produces uniquely-named targets, e.g.:
```
test_vcs_mmu_ifu_test_s374648616
test_vcs_mmu_ifu_test_s883261267
test_vcs_mmu_lsu_test_s66622511
```
Seeds are unique per test, and each test gets its **own** independent seed set.
Values are 31-bit positive integers (valid for `+ntb_random_seed` and `+PT_SEED`).

**Reproducibility.** Each invocation picks a fresh master seed and records it in
the yaml header:
```
# Random seeds generated with --master-seed 462892579
# (re-run with the same --master-seed to reproduce this exact seed set)
```
Re-running with that `--master-seed` regenerates a byte-identical yaml, so a
regression's seed set is always recoverable from the file itself:
```bash
regress/runreg.py --random -n 10 --master-seed 462892579 --out regress/nightly.yaml
```

Note: with multiple `--sims`, the same test gets *different* seeds per simulator
(the RNG advances per target). If you need identical seeds across simulators for
a like-for-like comparison, generate one yaml per simulator with the same
`--master-seed`:
```bash
regress/runreg.py --random -n 5 --master-seed 7 --sims vcs       --out regress/vcs.yaml
regress/runreg.py --random -n 5 --master-seed 7 --sims verilator --out regress/vlt.yaml
```

Per-test extra plusargs (fault modes, `+PT_DYNAMIC`, etc.) live in the `TESTS`
dict at the top of `runreg.py`. Seeds are applied automatically as
`PT_SEED=<s>` and `+PT_SEED=<s>`.

## Validating without submitting
Dry-walk the DAG (parses yaml, resolves deps, runs nothing):
```bash
regress/runreg.py regress/mmu_smoke.yaml --dry-run
```

## Notes
- Each test target runs `make run ... RUNDIR=$(BUILD)/<test>_seed<seed>`; logs
  land under `build/<test>_seed<seed>/run.log`. Pass/fail is taken from the
  command exit status (non-zero `make run` = failed target).
- Regression run dirs are written under `regressions/<name>+<id>/`.
- To add a test: drop it in `sv/tests/`, add it to the `TESTS` map (with any
  per-test plusargs), and regenerate.