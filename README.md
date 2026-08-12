# tt-riscv-mmu-tb

A **reusable UVM framework for verifying a RISC-V MMU**, with the XuanTie
OpenC910 MMU (`ct_mmu_top`) wired up as the worked example. The agent layer,
the page-table generator, the reference-model comparison, and the scoreboard
ladder are DUT-agnostic; everything C910-specific is isolated behind virtual
seams so another MMU can be dropped in by replacing those pieces rather than
rewriting the environment.

The example DUT translates both instruction-fetch (**IFU**) and load/store
(**LSU**) accesses in Sv39 / Bare modes. Page tables are generated **live
in-sim** with riescue (via a `PageTableSV` pysv/DPI bridge, no container), and
the DUT's memory is backed by the `sysmem` + `mem-manager` DPI engine.

Agents drive the **IFU**, **LSU**, **CSR**, **PTW-memory**, **PMP** and
**TLB-maintenance** interfaces. Every translation is scored against the Whisper
reference model, with fault injection on both the instruction and data sides.

## Reference model and scoring

Each completed translation is compared against Whisper (`external/tt-whisper-mmu`,
linked into the simulator as `libdvmmu.a`). The scoreboard is split in two:


| File                                 | Role                                                                                                            |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------------- |
| `sv/checkers/mmu_scoreboard_base.sv` | DUT-agnostic 4-case ladder (both-OK / both-fault / model-OK+DUT-fault / model-fault+DUT-OK), with virtual seams |
| `sv/checkers/mmu_scoreboard.sv`      | C910 specialisation via those seams                                                                             |
| `sv/checkers/mmu_c910_pma_pmp.sv`    | sysmap (PMA) + PMP fault predictor                                                                              |


Whisper models neither C910's sysmap nor its PMP semantics, so `mmu_c910_pma_pmp`
supplies every expected ACCESS fault. **Whisper's own PMP is deliberately left
unprogrammed** — C910 checks each PTE fetch by the *originating* access type
(fetch→X, load→R, store→W), which diverges from Whisper's read-as-user model.

## Requirements

- **Verilator** (default simulator) — see *Verilator* below for how it is located.
- **GCC ≥ 10** for the DPI C++ (the sources are C++20; older `g++` rejects
`-std=c++20`). Put one on `PATH` before building, or set `CXX` explicitly.
- **Python ≥ 3.9** with a shared `libpython`, plus the pip packages in
`requirements.txt`:
  ```
  python3 -m pip install --user -r requirements.txt
  ```
- **z3** — Verilator implements SV `randomize()` via an external SMT solver, so
constrained-random tests (`+PT_DYNAMIC`, `+PMP`) fail without one. The
`z3-solver` package above provides it; the build also accepts a `z3` on `PATH`,
or point at one explicitly with `VERILATOR_SOLVER=/path/to/z3`. VCS has its own
solver and needs none of this.
- Submodules initialised — `--recursive` **is required**, since the Whisper
submodule has a nested one of its own:
  ```
  git submodule sync --recursive
  git submodule update --init --recursive
  ```

  | Submodule                   | Source                                       |
  | --------------------------- | -------------------------------------------- |
  | `rtl/openc910`              | OpenC910 RTL (the DUT)                       |
  | `external/riescue`       | page-table generator                         |
  | `external/tt-whisper-mmu` | reference model; nests `whisper` (swerv-iss) |
  | `external/mem-manager`      | `github.com/tenstorrent/mem-manager`         |

  **Run both commands after every `git pull`, not just on first clone.** Git
  caches each submodule's URL in `.git/config` and a plain `pull` does not
  refresh it, so when a submodule URL changes your clone keeps fetching from the
  old one. `sync` rewrites those cached URLs from `.gitmodules`; `update` then
  checks out the recorded commit.

  Symptoms of skipping it: `did not contain <sha>. Direct fetching of that
  commit failed`, a fetch against a host you no longer use, or a build that
  silently uses stale sources. Check with:
  ```
  git submodule status --recursive     # a leading '+' means out of date
  ```

- **VCS** (optional; `SIM=vcs`, set via `VCS_HOME`) — also exercised by `make smoke`.
No licence servers are baked into the repo, so export your own before using
`SIM=vcs`:
  ```
  export SNPSLMD_LICENSE_FILE=<port>@<host>[:<port>@<host>...]
  export LM_LICENSE_FILE=<port>@<host>
  ```



## Running tests

```
make run TEST=<test_name> [+plusargs...]
```

Pass plusargs **bare** on the command line, e.g.:

```
make run TEST=mmu_ifu_test +PT_DYNAMIC +PT_FAULTS=USER +PT_SEED=7 +fsdb
```

`TEST=` maps to `+UVM_TESTNAME` (and labels the run dir via `+PT_SEED=`). With
no plusargs the default is a fixed static config + seed 1. The quoted form
`ARGS="+PT_DYNAMIC +PT_SEED=7 ..."` also works if you prefer.

Tests:


| Test                    | What it does                                                                                                                                                          |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `mmu_base_test`         | Brings up UVM + DUT, no stimulus (smoke of the build).                                                                                                                |
| `mmu_ifu_test`          | Drives IFU fetch translations: warm hits back-to-back, cold misses held to completion, ~5% speculative misses abandoned via `ifu_mmu_abort`, ~0.5% non-canonical VAs. |
| `mmu_lsu_test`          | Data loads + stores across both duTLB pipes (cold misses via id-wakeup-replay), with data-side fault injection.                                                       |
| `mmu_ifu_lsu_test`      | IFU and LSU streams running concurrently, contending for the shared jTLB and the single PTW.                                                                          |
| `mmu_tlb_inv_test`      | `sfence.vma` / TLB-maintenance ops interleaved with live traffic; a backdoor CAM checker verifies which entries survive each flush.                                   |
| `mmu_dynamic_satp_test` | Mid-run `satp` switches (PPN and/or ASID), page-table regeneration, and optional PMP/PMA reprogramming.                                                               |
| `mmu_csr_reg_test`      | CSR read/write behaviour on the CP0 interface.                                                                                                                        |
| `mmu_ptcfg_gen_test`    | Exercises the DUT-agnostic page-table config generator (`sv/cfg`).                                                                                                    |




## Verilator

```bash
make run TEST=mmu_ifu_test +PT_DYNAMIC +PT_SEED=7        # verilator is the default
```

| Variable | Default | Meaning |
|---|---|---|
| `SIM` | `verilator` | `verilator \| vcs \| xcelium \| questa` |
| `VERILATOR_UVM` | `1` | `1` builds and runs the UVM testbench; `0` only lints/elaborates the synthesizable DUT |
| `VERILATOR_VERSION` | `v5.050` | version used for the source-build fallback |

Set `VERILATOR_UVM=0` for a lint-only pass that does not run the testbench.
Use `SIM=vcs` for the VCS flow.

### Pointing at a prebuilt Verilator

The binary is resolved in this order — the **first** hit wins:

| # | Source | Set via |
|---|---|---|
| 1 | `$VERILATOR_HOME/bin/verilator` | `VERILATOR_HOME=<install-prefix>` |
| 2 | `verilator` on `$PATH` | `export PATH=<prefix>/bin:$PATH` |
| 3 | `external/verilator/bin/verilator` | built from source as a last resort |

So any of these work:

```bash
# 1. explicit install prefix (most direct)
make run VERILATOR_HOME=/path/to/verilator TEST=mmu_ifu_test

# 2. already on PATH
export PATH=/path/to/verilator/bin:$PATH
make run TEST=mmu_ifu_test

# bypass discovery entirely and name the binary
make run VERILATOR=/path/to/bin/verilator TEST=mmu_ifu_test
```

**If none of the three resolve, the build clones and compiles Verilator from
source** into `external/verilator` (pinned to `VERILATOR_VERSION`) — many
minutes, and it fills `~/.ccache`. Point at a prebuilt one to avoid that; the
build prints which it selected:

```
Verilator present: Verilator 5.050 ...
```

Waves: `VERILATOR_WAVES=vcd|fst` enables tracing at build time (the `+fsdb`
plusarg is VCS-only). `VERILATOR_JOBS` defaults to `nproc`.

## Smoke and regression

```bash
make smoke                    # SMOKE_TESTS x SMOKE_SIMS, static page tables
make smoke SMOKE_DYNAMIC=1    # same, dynamic (randomized) page tables
make smoke-satp               # dynamic-satp smoke
```

Knobs: `SMOKE_TESTS` (default `mmu_ifu_test mmu_lsu_test mmu_ifu_lsu_test mmu_tlb_inv_test`), `SMOKE_SIMS` (default `verilator vcs`), `SMOKE_PT_SEED`.

Larger sweeps run through `regress/runreg.py` (a DAG runner) against
`regress/{mmu_smoke,regression,nightly}.yaml`:

```bash
export MMU_TB_ROOT=$(pwd)          # the YAMLs reference $MMU_TB_ROOT
./regress/runreg.py regress/regression.yaml --run
./regress/runreg.py --random -n 10 --run     # random-seed sweep
```



### Page-table config: what you can set

A riescue config (`+PT_CONFIG_JSON=<f>`, or what `+PT_DYNAMIC` builds in-sim)
looks like this:

```json
{
  "mmap":   [ ["0x80000000", "0x10000000000"] ],
  "spaces": {
    "space1": {
      "twostage":    false,
      "paging_mode": "sv39",
      "pages": [
        { "num_pages": 32, "id": "code",
          "pa_and": "0x000000FFFFFFF000",
          "attributes": { "size": "4kb", "r": 1, "w": 0, "x": 1, "u": 0, "a": 1, "d": 0 } }
      ]
    }
  }
}
```

**Top level** — `mmap` is a list of `[low, high]` physical windows (hex strings
or ints; the object form also takes `"secure"`). `spaces` maps a space id to a
space config.

**Per space** — `twostage`, `paging_mode`, `gstage_paging_mode`,
`secure_pt_probability`. `paging_mode` accepts a string, a list, or a weighted
list.

**Per page group** — `num_pages`, `id`, and VA/PA placement: `va`, `va_and`,
`va_or`, `pa`, `pa_and`, `pa_or`. The `_and`/`_or` forms mask and set bits on a
randomly chosen address, which is how you confine pages to a PA window.

#### PTE attributes

`attributes` is passed through to riescue, which applies each key onto the page
(`page_map.py`). **345 keys** are accepted in total: 20 base attributes, most of
which also have per-level and per-G-stage-level variants.

Base attributes, with defaults and which variants exist:

| Attribute | Default | `_level<N>` | `_level<N>_glevel<M>` | Meaning |
|---|---|---|---|---|
| `v` | 1 | 0–4 | 0–4 | valid |
| `r` | 1 | 0–4 | 0–4 | read |
| `w` | 1 | 0–4 | 0–4 | write |
| `x` | 1 | 0–4 | 0–4 | execute |
| `u` | *priv-dependent* | 0–4 | 0–4 | user page — forced to 1 in U-mode |
| `g` | 0 | 0–4 | 0–4 | global |
| `a` | unset | 0–4 | 0–4 | accessed |
| `d` | unset | 0–4 | 0–4 | dirty |
| `n` | unset | 0–4 | 0–4 | Svnapot |
| `pbmt` | 0 | 0–4 | 0–4 | page-based memory types |
| `rsw` | 0 | 0–4 | — | software-reserved bits |
| `reserved` | 0 | 0–4 | — | reserved-bit poisoning (fault injection) |
| `secure` | 0 | — | — | secure page |
| `modify_pt` | 0 | — | — | post-build page-table modification |
| `gstage_g` | 0 | 0–4 | — | G-stage global |
| `gstage_rsw` | 0 | 0–4 | — | G-stage software-reserved |
| `gstage_reserved` | 0 | 0–4 | — | G-stage reserved-bit poisoning |
| `gstage_pbmt` | 0 | — | — | G-stage PBMT |
| `gstage_n` | 0 | — | — | G-stage Svnapot |
| `gstage_modify_pt` | 0 | — | — | G-stage post-build modification |

**Per-level variants.** Any attribute with a range above can be set at a
specific walk level instead of (or as well as) the page as a whole:

```
<attr>_level<N>              N = 0..4    VS-stage / single-stage walk level
<attr>_level<N>_glevel<M>    M = 0..4    G-stage level within that VS level
```

Levels 0–2 are the Sv39 walk; 3 and 4 exist for Sv48/Sv57. This is how you
inject a fault at a **non-leaf** level rather than the leaf — e.g. `"v_level1": 0`
makes the level-1 PTE invalid, faulting mid-walk.

**Weighted randomization.** Every attribute accepts a weighted list instead of a
scalar:

```json
"attributes": { "w": [ {"value": 1, "weight": 90}, {"value": 0, "weight": 10} ] }
```

**On this DUT.** C910 is Sv39 single-stage, so the `gstage_*` / `_glevel<M>`
attributes and levels 3–4 have no effect, and `n`/`pbmt` must stay unset (C910
reuses those PTE bits for MAEE). `sv/cfg/` encodes those limits so the in-sim
generator only emits legal combinations — but the fields above are all accepted
by riescue and are available for other targets.

### Page-table sourcing

The IFU test drives ~500 randomly-selected VAs (single pass, shuffled) and, on
each, back-to-back streams warm hits, holds cold misses to completion, and
abandons ~5% speculative misses via `ifu_mmu_abort`. Every completed translation
(success or fault) is checked against Whisper.

Pick the source with a plusarg in `ARGS` (default = static config file):


| Plusarg               | Meaning                                                   |
| --------------------- | --------------------------------------------------------- |
| *(none)*              | `+PT_CONFIG_JSON=<default>` — fixed config file (default) |
| `+PT_CONFIG_JSON=<f>` | parse a fixed riescue config file                         |
| `+PT_OUTPUT_JSON=<f>` | parse a pre-generated gen_pages output                    |
| `+PT_DYNAMIC`         | randomize a config in-sim                                 |
| `+PT_SEED=<n>`        | generation seed (reproducible)                            |


Fault plusargs (only with `+PT_DYNAMIC`):


| Plusarg                  | Meaning                                                                       |
| ------------------------ | ----------------------------------------------------------------------------- |
| *(none)*                 | faults randomized on/off per seed (0–2 types; NO-FAULT is a weighted outcome) |
| `+PT_FAULTS`             | force ≥1 fault, type(s) randomly picked                                       |
| `+PT_FAULTS=NOEXEC,USER` | force exactly those types (`NOEXEC,USER,NOACC,INVALID,RESERVED`)              |
| `+PT_NO_FAULT`           | force a clean (no-fault) config                                               |


PMP plusargs:


| Plusarg        | Meaning                                                                                   |
| -------------- | ----------------------------------------------------------------------------------------- |
| *(none)*       | one full-coverage permissive entry (PMP effectively off)                                  |
| `+PMP`         | randomized 16-entry config; 95% of regions grant RWX, 5% take a randomized permission mix |
| `+PMP_DYNAMIC` | reprogram PMP mid-run                                                                     |
| `+PMP_OFF`     | force every region fully permissive                                                       |


A randomized deny region may legitimately overlap the page tables, in which case
the DUT aborts the walk with an access fault — `mmu_c910_pma_pmp` predicts this
and scores it.

CSR / privilege plusargs:


| Plusarg              | Meaning                                                 |
| -------------------- | ------------------------------------------------------- |
| `+MMUTB_EN_CSR_RAND` | randomize privilege, `SUM`, `MXR`, `MPRV`/`MPP` mid-run |


Stimulus-shaping plusargs:


| Plusarg                         | Meaning                                            |
| ------------------------------- | -------------------------------------------------- |
| `+MMU_NUM_REQS=<n>`             | number of translation requests                     |
| `+MMU_NUM_INVAL=<n>`            | number of TLB-maintenance ops (`mmu_tlb_inv_test`) |
| `+MMU_INV_TRAFFIC_REQS=<n>`     | traffic requests forked alongside invalidations    |
| `+MMU_NUM_SATP_SWITCHES=<n>`    | `satp` switches (`mmu_dynamic_satp_test`)          |
| `+MMU_SATP_ASID_REUSE_PCT=<n>`  | % of switches that reuse an ASID                   |
| `+MMU_SATP_PMA_PMP_PCT=<n>`     | % of switches that also reprogram PMP/PMA          |
| `+MMU_SATP_ENABLE_GLOBAL_PAGES` | allow global (G=1) pages across switches           |


Waveform plusargs:


| Plusarg            | Meaning                       |
| ------------------ | ----------------------------- |
| `+fsdb`            | dump `dump.fsdb` (Verdi/FSDB) |
| `+fsdbfile=<name>` | override the FSDB filename    |
| `+wave`            | dump `dump.vcd` (VCD)         |


**C910-scoped generator.** `mmu_pt_config_gen` models only what the C910
supports: **Sv39, single-stage**, page sizes **4KB/2MB/1GB**, permission-weighted
pages (RWX/RX/RW/R), and page-fault causes only — `EXECUTE`, `USER`, `ACCESSED`,
`VALID`, `RESERVED` — **never N(Svnapot)/PBMT** (those PTE bits are MAEE-reused
on C910). Faults use per-level weighting, so they also hit non-leaf walk levels.
Since `gen_pages` is open source, extend the config (more page groups/attributes/
sizes) for whatever your target RTL supports.

**Non-canonical VA faults.** ~0.5% of IFU fetches use a non-canonical Sv39 VA to exercise the IUTLB illegal-VA page fault (checked against Whisper).

Examples:

```
# default (static config file)
make run TEST=mmu_ifu_test

# static config file, specific seed
make run TEST=mmu_ifu_test +PT_CONFIG_JSON=$(pwd)/scripts/pt_gen_configs/sv39_nofaults_40bit.json +PT_SEED=42

# dynamic randomized config (faults randomized on/off), seeded
make run TEST=mmu_ifu_test +PT_DYNAMIC +PT_SEED=7

# dynamic, force faults (random types)
make run TEST=mmu_ifu_test +PT_DYNAMIC +PT_FAULTS +PT_SEED=7

# dynamic, force specific fault types
make run TEST=mmu_ifu_test +PT_DYNAMIC +PT_FAULTS=NOEXEC,USER +PT_SEED=7

# parse a pre-generated output.json
make run TEST=mmu_ifu_test +PT_OUTPUT_JSON=$(pwd)/path/to/output.json +PT_SEED=1

# dump an FSDB waveform (Verdi)
make run TEST=mmu_ifu_test +PT_DYNAMIC +PT_SEED=7 +fsdb

make clean
```

> `+PT_SEED=` also labels the per-run output dir; override with `RUNDIR=...` for a
> custom dir. `+PT_FAULTS` (bare, no value) forces ≥1 fault with random types;
> `+PT_FAULTS=NOEXEC,USER` forces specific types.

`make run` sets the Python env (`PYTHONPATH`, `PYTHONHOME` unset) needed by the
in-sim generator automatically, and runs from the per-run dir so artifacts land
in `build/<test>_seed<seed>/`: `run.log`, `generated_pt_config.json` (dynamic),
`generated_pt_output.json`, `whisper.log`

## Contributing

Bugs are reported via [GitHub Issues](../../issues); bug fixes and new
functionality are submitted via Pull Requests, which are reviewed on a weekly
cadence. See [CONTRIBUTING.md](CONTRIBUTING.md) for details, and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community expectations. To report a
security vulnerability, follow [SECURITY.md](SECURITY.md) instead of opening a
public issue.

## License

| File | Applies to |
|------|------------|
| [LICENSE](LICENSE) (Apache License 2.0) | Overall license for this project, except where specified |
| [LICENSE-DOCS](LICENSE-DOCS) (CC BY 4.0) | License for documentation and images only (Markdown files) |
| [LICENSE_understanding.txt](LICENSE_understanding.txt) | Tenstorrent's clarification of how the Apache 2.0 license applies to this repository |

Third-party components included as submodules or bundled sources (e.g.
`rtl/openc910`, `external/`, `third_party/`) retain their own upstream licenses;
see [NOTICE](NOTICE) for attributions.