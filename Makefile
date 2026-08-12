#=======================================================================
# Makefile - OpenC910 MMU plain-UVM testbench
#
# Vendor-neutral entry points. Set SIM to select a simulator backend.
# No Bazel; standard UVM flow only.
#
#   make compile   - compile RTL + TB
#   make run       - compile then run the default test
#   make clean     - remove build artifacts
#
# Variables:
#   SIM      = verilator | vcs | xcelium | questa   (default: verilator)
#              VERILATOR_UVM=1 (default) builds and runs the UVM testbench;
#              set VERILATOR_UVM=0 to only lint/elaborate the DUT.
#   TEST     = UVM test name            (default: mmu_base_test)
#   UVM_HOME = path to UVM library (required by some simulators)
#=======================================================================

SIM      ?= verilator
TEST     ?= mmu_base_test
TOP       = mmu_tb_top
FILELIST  = filelist.f
BUILD     = build

# '+' marks a real simv plusarg; make variables (TEST, SIM, VERILATOR_UVM,
# PT_CONFIG) take none. Plusargs may be bare, or quoted via ARGS="...":
#   make run TEST=mmu_ifu_test +PT_DYNAMIC +PT_FAULTS=USER +PT_SEED=7 +fsdb
#   make run TEST=mmu_ifu_test ARGS="+PT_CONFIG_JSON=$(abspath cfg.json) +PT_SEED=3"
# Page-table plusargs (choose one source): +PT_DYNAMIC | +PT_OUTPUT_JSON=<f> |
#   +PT_CONFIG_JSON=<f> ; fault knobs (with +PT_DYNAMIC): +PT_FAULTS[=NOEXEC,USER]
#   | +PT_NO_FAULT ; seed: +PT_SEED=<n> ; waves: +fsdb [+fsdbfile=<name>] | +wave.
PT_CONFIG ?= scripts/pt_gen_configs/sv39_nofaults_40bit.json
PT_SEED   ?= 1

# NOTE: GNU make parses any 'word=word' token as a variable assignment, so bare
# valued plusargs (+PT_SEED=7) arrive as make vars literally named '+PT_SEED';
# value-less ones (+PT_DYNAMIC, +fsdb) arrive as goals, collected into ARGS and
# given no-op targets below so make doesn't try to build them.
PLUS_VALUELESS := $(filter +%,$(MAKECMDGOALS))   # +PT_DYNAMIC +fsdb +wave +PT_FAULTS +PT_NO_FAULT
$(PLUS_VALUELESS):                                # no-op targets so make doesn't build them
	@:

# +PT_SEED= is a real plusarg that must also reach the make var (it labels the
# run dir); +TEST= is a back-compat alias for TEST= -- there is no +TEST plusarg.
ifneq ($(+TEST),)
  TEST := $(+TEST)
endif
ifneq ($(+PT_SEED),)
  PT_SEED := $(+PT_SEED)
endif

ifeq ($(ARGS),)
  BARE_ARGS := $(PLUS_VALUELESS)
  ifneq ($(+PT_SEED),)
    BARE_ARGS += +PT_SEED=$(+PT_SEED)
  endif
  ifneq ($(+PT_FAULTS),)
    BARE_ARGS += +PT_FAULTS=$(+PT_FAULTS)
  endif
  ifneq ($(+PT_CONFIG_JSON),)
    BARE_ARGS += +PT_CONFIG_JSON=$(+PT_CONFIG_JSON)
  endif
  ifneq ($(+PT_OUTPUT_JSON),)
    BARE_ARGS += +PT_OUTPUT_JSON=$(+PT_OUTPUT_JSON)
  endif
  ifneq ($(+fsdbfile),)
    BARE_ARGS += +fsdbfile=$(+fsdbfile)
  endif
  ifneq ($(BARE_ARGS),)
    ARGS := $(BARE_ARGS)
  endif
endif

# Default page-table SOURCE when ARGS supplies none. The seed is NOT here: this
# whole variable is dropped when the caller picks a source (+PT_DYNAMIC etc),
# which used to take +PT_SEED down with it and silently fall back to seed 1.
# See PT_SEED_ARG below, which is emitted either way.
DEFAULT_ARGS = +PT_CONFIG_JSON=$(abspath $(PT_CONFIG))

# EXTRA_ARGS is ALWAYS appended. Use it for additive plusargs like waveforms:
#   make run ... EXTRA_ARGS="+wave +wavefile=build/dump.fst"
EXTRA_ARGS ?=
ifneq ($(+wavefile),)
  EXTRA_ARGS += +wavefile=$(+wavefile)
endif

# Final plusargs for the sim. The page-table source (DEFAULT_ARGS) is included
# UNLESS the caller's ARGS already supplies one (+PT_CONFIG_JSON/+PT_OUTPUT_JSON/
# +PT_DYNAMIC), so e.g. ARGS="+wave ..." does NOT drop the PT config. ARGS and
# EXTRA_ARGS are always appended.
PT_SRC_IN_ARGS := $(filter +PT_CONFIG_JSON=% +PT_OUTPUT_JSON=% +PT_DYNAMIC +PT_DYNAMIC=%,$(ARGS))
# Stop the sim at the first uvm_error (fail-fast). Override with QUIT=<n>
# (0 = unlimited). Skipped if the caller already passes +UVM_MAX_QUIT_COUNT.
QUIT ?= 1
QUIT_ARG := $(if $(filter +UVM_MAX_QUIT_COUNT=%,$(ARGS) $(EXTRA_ARGS)),,+UVM_MAX_QUIT_COUNT=$(QUIT))
# Seed the SV stimulus RNG (priv/VA-pick/store/fault-selection) with the SAME
# value as PT_SEED, by convention (+ntb_random_seed=<s>
# +PT_SEED=<s>): the whole run is deterministic AND different seeds diversify the
# full stimulus, not just the page tables. Take the seed from ARGS if the caller
# passed +PT_SEED there, else the PT_SEED var. Skipped if the caller already
# supplies +ntb_random_seed. (+ntb_random_seed is a VCS runtime arg; Verilator
# ignores it harmlessly.)
ARGS_SEED       := $(patsubst +PT_SEED=%,%,$(filter +PT_SEED=%,$(ARGS)))
EFFECTIVE_SEED  := $(if $(ARGS_SEED),$(ARGS_SEED),$(PT_SEED))
# Seed the SV stimulus RNG with the SAME value on BOTH simulators so runs are
# deterministic and different seeds diversify the full stimulus (not just the
# page tables). The runtime plusarg is simulator-specific:
#   VCS       -> +ntb_random_seed=<s>
#   Verilator -> +verilator+seed+<s>   (VCS's +ntb_random_seed is ignored by
#                                        Verilator, which is why Verilator runs
#                                        previously diverged from VCS).
# Skipped if the caller already supplies the sim's own seed plusarg.
ifeq ($(SIM),verilator)
  SEED_ARG := $(if $(filter +verilator+seed+%,$(ARGS) $(EXTRA_ARGS)),,+verilator+seed+$(EFFECTIVE_SEED))
else
  SEED_ARG := $(if $(filter +ntb_random_seed=%,$(ARGS) $(EXTRA_ARGS)),,+ntb_random_seed=$(EFFECTIVE_SEED))
endif
# Page-table generator seed. Emitted independently of DEFAULT_ARGS so that
# `PT_SEED=<n> ARGS="+PT_DYNAMIC"` seeds the generator; skipped if the caller
# already put +PT_SEED in ARGS.
PT_SEED_ARG     = $(if $(filter +PT_SEED=%,$(ARGS) $(EXTRA_ARGS)),,+PT_SEED=$(EFFECTIVE_SEED))
RUN_PLUSARGS    = $(if $(strip $(PT_SRC_IN_ARGS)),,$(DEFAULT_ARGS)) $(PT_SEED_ARG) $(QUIT_ARG) $(SEED_ARG) $(ARGS) $(EXTRA_ARGS)

# Per-run output directory (override with RUNDIR=...). Holds compile.log, run.log.
# Per-run output dir. MUST include $(SIM): regressions run the same TEST+PT_SEED
# on several simulators, and an unqualified path made those targets share one
# run.log, so concurrent runs clobbered each other (spurious "no UVM report
# summary" failures). Keeps the *_seed* glob used by runreg.py --clean.
RUNDIR    ?= $(BUILD)/$(SIM)_$(TEST)_seed$(PT_SEED)

RIESCUE_DIR ?= external/riescue

# Whisper reference model (libdvmmu.a) + its DPI wrapper, compiled into simv.
# Built with the project CXX (gcc-toolset-11); OFLAGS= drops the model's -g so
# the system assembler suffices (its DWARF-4 output needs newer binutils).
DVMMU_DIR   = external/tt-whisper-mmu
DVMMU_LIB   = $(DVMMU_DIR)/libdvmmu.a
WHISPER_DIR = sv/checkers
WHISPER_OBJ = $(BUILD)/whisper_dv_mmu_dpi.o

# In-sim pysv page-table generator (PageTableSV over DPI, embedded riescue).
# Codegen -> PageTableSV.{cc,_pkg.sv}; PageTableSV.o is linked into simv.
# Paths auto-derive from python3; override for a different site. PY_SHLIB must
# be a SHARED libpython whose minor matches PY_INC.
PYSV_DIR    = $(BUILD)/pysv_gen
PY_INC     ?= $(shell python3 -c "import sysconfig;print(sysconfig.get_path('include'))")
PYBIND_INC ?= $(shell python3 -c "import os,pysv;print(os.path.join(os.path.dirname(pysv.__file__),'extern'))")
PY_SHLIB   ?= /usr/lib64/libpython3.11.so.1.0
PY_SITE    ?= $(shell python3 -c "import site;print(site.getusersitepackages())")

# Shared staging dir for the Python runtime. simv links against PY_SHLIB, which
# on some LSF exec nodes is not installed system-wide (simv then dies with
# "libpython3.11.so.1.0: cannot open shared object file"). stage-pylib copies it
# here (inside the workspace = shared storage) and run-only prepends this dir to
# LD_LIBRARY_PATH, so tests are node-independent.
PY_RUNTIME_DIR ?= $(BUILD)/lib

# Runtime PYTHONPATH for the embedded interpreter. IMPORTANT: leave PYTHONHOME
# UNSET — pysv only preserves our sys.path when PYTHONHOME is not set.
PT_PYTHONPATH = $(abspath scripts):$(abspath $(RIESCUE_DIR)):$(PY_SITE)

# C++ toolchain for the DPI bridges (pysv + sysmem). Needs GCC >= 10: the
# sysmem/mem-manager sources use C++20 (<bit>). System g++ (8.5) is too old.
# Plain '=' (not '?=') so it overrides make's built-in CXX default; a
# command-line `make CXX=...` still wins.
CXX ?= g++ 

# Physical-memory DPI backend (the DUT/TB memory). Compiled into simv.
#
#   C++  : external/mem-manager (submodule, Apache-2.0, public on GitHub)
#          storage engine + image loaders + the sized read/write/check DPI.
#   SV   : sv/sysmem -- the sysmem / address_space (named address space)
#          layers, implemented in SystemVerilog over the mem_manager DPI.
#
# Only the mem_manager C++ is compiled here; everything above it is SV.
MEMMGR_DIR    = external/mem-manager/src
SYSMEM_OBJDIR = $(BUILD)/sysmem_obj
SYSMEM_SRCS   = $(MEMMGR_DIR)/util.cc $(MEMMGR_DIR)/mem.cc $(MEMMGR_DIR)/mem_manager.cc \
                $(MEMMGR_DIR)/sparse_mem.cc
SYSMEM_OBJS   = $(SYSMEM_OBJDIR)/util.cc.o $(SYSMEM_OBJDIR)/mem.cc.o \
                $(SYSMEM_OBJDIR)/mem_manager.cc.o $(SYSMEM_OBJDIR)/sparse_mem.cc.o

#-----------------------------------------------------------------------
# Tool environment (override on the command line if your site differs)
#-----------------------------------------------------------------------
VCS_HOME             ?= /tools_vendor/synopsys/vcs/X-2025.06-SP2
# No licence servers are baked into the repo: export SNPSLMD_LICENSE_FILE
# (Synopsys) and LM_LICENSE_FILE (FlexLM) in your environment. Both are
# inherited by the recipes automatically.
# Verdi FSDB. VCS auto-links the PLI from VERDI_HOME (with -kdb
# -debug_access+all), so it must match VCS_HOME's release -- derived from it by
# default. No Verdi => no +define+FSDB_EN => mmu_tb_top.sv drops the $fsdbDump*
# calls, which would otherwise be unresolved system tasks and fail the build.
VERDI_HOME           ?= /tools_vendor/synopsys/verdi/$(notdir $(VCS_HOME))
FSDB_DEF             := $(if $(wildcard $(VERDI_HOME)),+define+FSDB_EN,)

export VCS_HOME
export VERDI_HOME
export PATH := $(VCS_HOME)/bin:$(PATH)

.PHONY: all compile run run-only stage-pylib clean help ptgen smoke

# Copy the Python shared lib into the workspace (shared storage) so simv can
# resolve it on farm nodes that lack the system package. No-op if already
# staged or if PY_SHLIB is missing (then we fall back to the system path).
# MUST be parallel-safe: every run-only target depends on this, so a regression
# with -jN invokes it N times concurrently. A plain "if missing then cp" is a
# check-then-act race -- two jobs both see the file absent, both copy, and the
# loser dies with "cp: cannot create regular file ...: File exists" (cp creates
# with O_EXCL), failing an otherwise good test. So: copy to a PID-unique temp
# and atomically rename it into place. The rename also means a concurrent reader
# never observes a half-written library. Losing the race is not an error.
stage-pylib:
	@mkdir -p $(PY_RUNTIME_DIR)
	@dst="$(PY_RUNTIME_DIR)/$(notdir $(PY_SHLIB))"; \
	if [ -f "$(PY_SHLIB)" ] && [ ! -s "$$dst" ]; then \
	  tmp="$$dst.tmp.$$$$"; \
	  if cp -L "$(PY_SHLIB)" "$$tmp" 2>/dev/null && mv -f "$$tmp" "$$dst" 2>/dev/null; then \
	    echo "stage-pylib: staged $(notdir $(PY_SHLIB)) -> $(PY_RUNTIME_DIR)"; \
	  fi; \
	  rm -f "$$tmp"; \
	fi; \
	exit 0

all: run

help:
	@echo "Targets: compile | run | clean | ptgen | smoke   (SIM=$(SIM) TEST=$(TEST))"
	@echo "  smoke: run \$$(SMOKE_TESTS) on \$$(SMOKE_SIMS) [$(SMOKE_SIMS)]"

#-----------------------------------------------------------------------
# Smoke: run a fixed list of quick tests across simulators (verilator + vcs).
# Add future tests by appending to SMOKE_TESTS (or pass on the command line):
#   make smoke SMOKE_TESTS="mmu_ifu_test my_new_test"
#   make smoke SMOKE_SIMS=verilator          # one simulator only
#-----------------------------------------------------------------------
SMOKE_TESTS     ?= mmu_ifu_test mmu_lsu_test mmu_ifu_lsu_test mmu_tlb_inv_test
SMOKE_SIMS      ?= verilator vcs
SMOKE_PT_CONFIG ?= $(PT_CONFIG)
SMOKE_PT_SEED   ?= $(PT_SEED)
# SMOKE_DYNAMIC=1 uses +PT_DYNAMIC (randomized page tables + fault injection)
# instead of the static SMOKE_PT_CONFIG file. Seed stays fixed (SMOKE_PT_SEED).
SMOKE_DYNAMIC   ?= 0

smoke:
	@rc=0; \
	for sim in $(SMOKE_SIMS); do \
	  for t in $(SMOKE_TESTS); do \
	    echo "==================================================================="; \
	    echo "SMOKE: $$t on $$sim"; \
	    echo "==================================================================="; \
	    log="$(BUILD)/$${sim}_$${t}_seed$(SMOKE_PT_SEED)/run.log"; \
	    ok=1; \
	    if [ "$(SMOKE_DYNAMIC)" = "1" ]; then \
	      pt_args="ARGS=+PT_DYNAMIC"; \
	    else \
	      pt_args="PT_CONFIG=$(SMOKE_PT_CONFIG)"; \
	    fi; \
	    if [ "$$sim" = "verilator" ]; then \
	      $(MAKE) run SIM=verilator VERILATOR_UVM=1 TEST=$$t \
	        $$pt_args PT_SEED=$(SMOKE_PT_SEED) || ok=0; \
	    else \
	      $(MAKE) run SIM=$$sim TEST=$$t \
	        $$pt_args PT_SEED=$(SMOKE_PT_SEED) || ok=0; \
	    fi; \
	    errc=$$(sed -nE 's/.*UVM_ERROR :[[:space:]]+([0-9]+).*/\1/p' "$$log" 2>/dev/null | tail -1); \
	    fatc=$$(sed -nE 's/.*UVM_FATAL :[[:space:]]+([0-9]+).*/\1/p' "$$log" 2>/dev/null | tail -1); \
	    if [ ! -f "$$log" ]; then echo "SMOKE FAIL: $$t on $$sim (no run.log)"; ok=0; \
	    elif [ -z "$$fatc" ] || [ -z "$$errc" ]; then echo "SMOKE FAIL: $$t on $$sim (no UVM report summary - crashed?)"; ok=0; \
	    elif [ "$$fatc" != "0" ]; then echo "SMOKE FAIL: $$t on $$sim (UVM_FATAL=$$fatc)"; ok=0; \
	    elif [ "$$errc" != "0" ]; then echo "SMOKE FAIL: $$t on $$sim (UVM_ERROR=$$errc)"; ok=0; \
	    fi; \
	    if [ $$ok -eq 1 ]; then echo "SMOKE ok: $$t on $$sim"; else rc=1; fi; \
	  done; \
	done; \
	if [ $$rc -eq 0 ]; then echo "SMOKE PASS: all [$(SMOKE_SIMS)] x [$(SMOKE_TESTS)]"; \
	else echo "SMOKE: one or more runs FAILED"; fi; \
	exit $$rc

#-----------------------------------------------------------------------
# Dynamic-satp smoke: mmu_dynamic_satp_test needs +PT_DYNAMIC (randomized
# per-context page tables) and has a global-page variant, so it does not fit
# the flat SMOKE_TESTS/shared-args loop. Runs 4 gating variants (1 seed each):
#   {vcs, verilator} x {default, +MMU_SATP_ENABLE_GLOBAL_PAGES}
# Fails if any run reports UVM_ERROR/UVM_FATAL != 0.
#-----------------------------------------------------------------------
SATP_SMOKE_SEED ?= $(PT_SEED)

smoke-satp:
	@rc=0; \
	for sim in verilator vcs; do \
	  for var in default global; do \
	    if [ "$$var" = "global" ]; then xargs="+MMU_SATP_ENABLE_GLOBAL_PAGES"; tag="global"; \
	    else xargs=""; tag="default"; fi; \
	    rd="$(BUILD)/satp_$${sim}_$${tag}"; \
	    echo "==================================================================="; \
	    echo "SMOKE-SATP: mmu_dynamic_satp_test on $$sim ($$tag)"; \
	    echo "==================================================================="; \
	    rm -rf $$rd; ok=1; \
	    if [ "$$sim" = "verilator" ]; then \
	      $(MAKE) run SIM=verilator VERILATOR_UVM=1 TEST=mmu_dynamic_satp_test \
	        RUNDIR=$$rd ARGS="+PT_DYNAMIC $$xargs" PT_SEED=$(SATP_SMOKE_SEED) QUIT=0 || ok=0; \
	    else \
	      $(MAKE) run SIM=vcs TEST=mmu_dynamic_satp_test \
	        RUNDIR=$$rd ARGS="+PT_DYNAMIC $$xargs" PT_SEED=$(SATP_SMOKE_SEED) QUIT=0 || ok=0; \
	    fi; \
	    log="$$rd/run.log"; \
	    errc=$$(sed -nE 's/.*UVM_ERROR :[[:space:]]+([0-9]+).*/\1/p' "$$log" 2>/dev/null | tail -1); \
	    fatc=$$(sed -nE 's/.*UVM_FATAL :[[:space:]]+([0-9]+).*/\1/p' "$$log" 2>/dev/null | tail -1); \
	    if [ ! -f "$$log" ]; then echo "SMOKE-SATP FAIL: $$sim/$$tag (no run.log)"; ok=0; \
	    elif [ -z "$$fatc" ] || [ -z "$$errc" ]; then echo "SMOKE-SATP FAIL: $$sim/$$tag (no UVM summary - crashed?)"; ok=0; \
	    elif [ "$$fatc" != "0" ]; then echo "SMOKE-SATP FAIL: $$sim/$$tag (UVM_FATAL=$$fatc)"; ok=0; \
	    elif [ "$$errc" != "0" ]; then echo "SMOKE-SATP FAIL: $$sim/$$tag (UVM_ERROR=$$errc)"; ok=0; \
	    fi; \
	    if [ $$ok -eq 1 ]; then echo "SMOKE-SATP ok: $$sim/$$tag"; else rc=1; fi; \
	  done; \
	done; \
	if [ $$rc -eq 0 ]; then echo "SMOKE-SATP PASS: [verilator vcs] x [default global]"; \
	else echo "SMOKE-SATP: one or more runs FAILED"; fi; \
	exit $$rc

#-----------------------------------------------------------------------
# DPI C++ build. Three bridges compiled into simv:
#   1. PageTableSV (pysv) — codegen PageTableSV.{cc,_pkg.sv}, compile against
#      the system shared libpython (bare-host in-sim page-table generation).
#   2. sysmem + mem-manager — the DUT/TB physical memory (C++20; -fpermissive
#      for mem.cc, -include bit for sparse_mem.cc; links lz4).
#   3. Whisper DvMmu reference model — build libdvmmu.a (OFLAGS= drops -g so the
#      system assembler suffices) + compile its DPI wrapper (whisper_dv_mmu_dpi).
#-----------------------------------------------------------------------
ptgen:
	mkdir -p $(PYSV_DIR) $(SYSMEM_OBJDIR)
	python3 scripts/gen_pysv.py $(PYSV_DIR)
	$(CXX) -std=c++17 -fPIC -I$(PY_INC) -I$(PYBIND_INC) -I$(VCS_HOME)/include \
	    -DPYTHON_LIBRARY='"$(PY_SHLIB)"' \
	    -c $(PYSV_DIR)/PageTableSV.cc -o $(PYSV_DIR)/PageTableSV.o
	for s in $(SYSMEM_SRCS); do \
	    $(CXX) -std=c++20 -fPIC -fpermissive -include bit \
	      -I$(MEMMGR_DIR) -I$(VCS_HOME)/include \
	      -c $$s -o $(SYSMEM_OBJDIR)/$$(basename $$s).o || exit 1; \
	done
	$(MAKE) -C $(DVMMU_DIR) CXX=$(CXX) OFLAGS= libdvmmu.a
	$(CXX) -std=c++20 -fPIC \
	    -I$(WHISPER_DIR) -I$(DVMMU_DIR) -I$(DVMMU_DIR)/whisper -I$(VCS_HOME)/include \
	    -c $(WHISPER_DIR)/whisper_dv_mmu_dpi.cpp -o $(WHISPER_OBJ)

#-----------------------------------------------------------------------
# VCS
#-----------------------------------------------------------------------
ifeq ($(SIM),vcs)
# Functional + code coverage: enable with COV=1. When off, MMU covergroups are
# compiled out (mmu_coverage_pkg's COVERAGE_UNSUPPORTED path) so default runs
# and Verilator lint are unaffected.
ifeq ($(COV),1)
VCS_COV_CMP = -cm line+cond+fsm+tgl+branch+assert -cm_dir $(BUILD)/cov.vdb +define+MMU_COVERAGE
VCS_COV_RUN = -cm line+cond+fsm+tgl+branch+assert -cm_dir $(abspath $(BUILD)/cov.vdb) -cm_name $(TEST)
else
VCS_COV_CMP =
VCS_COV_RUN =
endif

compile: ptgen
	mkdir -p $(BUILD)
	vcs -full64 -sverilog -ntb_opts uvm \
	    -kdb -debug_access+all $(FSDB_DEF) \
	    -timescale=1ns/1ps \
	    -cpp $(CXX) -ld $(CXX) \
	    $(VCS_COV_CMP) \
	    -f $(FILELIST) \
	    -top $(TOP) \
	    $(PYSV_DIR)/PageTableSV.o $(SYSMEM_OBJS) $(WHISPER_OBJ) $(DVMMU_LIB) \
	    -LDFLAGS "-L$(dir $(PY_SHLIB)) -l:$(notdir $(PY_SHLIB)) -lpthread -ldl -lutil -lm -L/usr/lib64 -llz4" \
	    -Mdir=$(BUILD)/csrc -o $(BUILD)/simv -l $(BUILD)/compile.log

# Page tables are generated live in-sim via PageTableSV (riescue over pysv/DPI).
# The base sequence calls PageTableSV, preloads memory, and programs satp.
run: compile run-only

# run-only: launch simv WITHOUT re-running compile/ptgen. Used by the regression
# flow, where a single build target compiles simv once and each test target
# reuses it — avoids recompiling C++ (ptgen/sysmem) on every exec node.
run-only: stage-pylib
	@mkdir -p $(RUNDIR)
	@if [ ! -x "$(BUILD)/simv" ]; then \
	  echo "run-only: $(BUILD)/simv not found — build first with 'make compile SIM=vcs'"; exit 1; fi
	@# Run FROM the per-run dir so riemap' output.json + whisper.log land
	@# there natively, no post-run moves needed. Paths are made
	@# absolute since cwd is now $(RUNDIR).
	@# PY_RUNTIME_DIR (shared, staged below) is prepended to LD_LIBRARY_PATH so
	@# simv resolves libpython even on farm nodes that lack the system package.
	unset PYTHONHOME; export PYTHONPATH="$(PT_PYTHONPATH)"; \
	export LD_LIBRARY_PATH="$(abspath $(PY_RUNTIME_DIR)):$(dir $(PY_SHLIB)):$$LD_LIBRARY_PATH"; \
	cd $(RUNDIR) && $(abspath $(BUILD)/simv) +UVM_TESTNAME=$(TEST) \
	    $(VCS_COV_RUN) \
	    $(RUN_PLUSARGS) \
	    -l run.log
	@# Gate pass/fail on the UVM report so regression harnesses (which judge by
	@# exit code) correctly flag runs with UVM_ERROR/UVM_FATAL or a crash.
	@log="$(RUNDIR)/run.log"; \
	full="$(abspath $(RUNDIR))/run.log"; \
	errc=$$(sed -nE 's/.*UVM_ERROR :[[:space:]]+([0-9]+).*/\1/p' "$$log" | tail -1); \
	fatc=$$(sed -nE 's/.*UVM_FATAL :[[:space:]]+([0-9]+).*/\1/p' "$$log" | tail -1); \
	if [ -z "$$errc" ] || [ -z "$$fatc" ]; then \
	  echo "RUN FAIL: $(TEST) (no UVM report summary in run.log — crashed?)"; \
	  echo "FULL LOG: $$full"; tail -20 "$$log" 2>/dev/null; exit 1; \
	elif [ "$$fatc" != "0" ] || [ "$$errc" != "0" ]; then \
	  echo "RUN FAIL: $(TEST) (UVM_ERROR=$$errc UVM_FATAL=$$fatc)"; \
	  echo "FULL LOG: $$full"; \
	  echo "--- first 20 UVM_ERROR/UVM_FATAL lines ---"; \
	  grep -E "UVM_(ERROR|FATAL)" "$$log" | grep -vE "UVM_(ERROR|FATAL) :" | head -20; \
	  exit 1; \
	else \
	  echo "RUN PASS: $(TEST) (UVM_ERROR=0 UVM_FATAL=0)"; \
	fi

# Merge + report coverage (run after one or more `make run COV=1`).
#   make cov_report                    # report from $(BUILD)/cov.vdb
cov_report:
	urg -full64 -dir $(BUILD)/cov.vdb -report $(BUILD)/cov_report
	@echo "Coverage report: $(BUILD)/cov_report/dashboard.html"
endif

#-----------------------------------------------------------------------
# Cadence Xcelium
#-----------------------------------------------------------------------
ifeq ($(SIM),xcelium)
compile run:
	mkdir -p $(BUILD)
	xrun -64bit -sv -uvm \
	    -timescale 1ns/1ps \
	    -f $(FILELIST) \
	    -top $(TOP) \
	    +UVM_TESTNAME=$(TEST) -l $(BUILD)/xrun.log
endif

#-----------------------------------------------------------------------
# Siemens Questa
#-----------------------------------------------------------------------
ifeq ($(SIM),questa)
compile:
	mkdir -p $(BUILD)
	vlib $(BUILD)/work
	vmap work $(BUILD)/work
	vlog -sv -mfcu +acc -timescale 1ns/1ps -f $(FILELIST) -l $(BUILD)/compile.log

run: compile
	vsim -c work.$(TOP) +UVM_TESTNAME=$(TEST) -do "run -all; quit" -l $(BUILD)/run.log
endif

#-----------------------------------------------------------------------
# Verilator  (open-source; NO UVM support)
#-----------------------------------------------------------------------
# Verilator cannot run the class-based UVM testbench. This backend only
# lints/elaborates the synthesizable OpenC910 MMU DUT (top: ct_mmu_top),
# which is useful as a fast RTL sanity/lint check.
#
#   make compile SIM=verilator                 # lint the DUT
#   make compile SIM=verilator VERILATOR_LINT=0 # full elaborate (--binary)
#
# Points at the locally built Verilator (v5.050) unless overridden.
ifeq ($(SIM),verilator)
# Verilator resolution (first hit wins):
#   1. $VERILATOR / $VERILATOR_HOME if set by the caller,
#   2. a 'verilator' already on PATH (system/package install),
#   3. a project-local build under external/verilator (auto-built by the
#      'verilator_build' target from pinned source).
# Prefer 1 or 2 over 3: building Verilator from source takes many minutes and
# fills ~/.ccache, which is what made CI run out of disk.
VERILATOR_REPO    ?= https://github.com/verilator/verilator
VERILATOR_VERSION ?= v5.050
VERILATOR_LOCAL   := $(abspath external/verilator)
VERILATOR_ONPATH  := $(shell command -v verilator 2>/dev/null)
# Some Verilator builds bake a linker into verilated.mk (CFG_LDFLAGS_VERILATED,
# e.g. -fuse-ld=mold). If that linker is not installed the link fails, so clear
# it unless mold is actually on PATH.
VLT_LDFLAGS_OVERRIDE := $(if $(shell command -v mold 2>/dev/null),,-MAKEFLAGS CFG_LDFLAGS_VERILATED=)
# VERILATOR_ROOT is Verilator's OWN variable and is NOT an install prefix (for an
# installed copy it is <prefix>/share/verilator; the wrapper sets it itself and
# errors on a mismatch). It used to be this knob's name, and make exports
# command-line variables, so the old spelling reached Verilator and broke it.
# Only complain when it is clearly meant as our knob, i.e. VERILATOR_HOME is unset.
ifdef VERILATOR_ROOT
ifndef VERILATOR_HOME
$(error VERILATOR_ROOT is Verilator's own variable; use VERILATOR_HOME=<install-prefix> instead)
endif
endif

# VERILATOR_HOME has NO default: defaulting it to VERILATOR_LOCAL made slot 1
# resolve to the local build, so an existing external/verilator silently shadowed
# a newer verilator on PATH -- the reverse of the documented order above.
VERILATOR         ?= $(firstword $(if $(VERILATOR_HOME),$(wildcard $(VERILATOR_HOME)/bin/verilator)) \
                                  $(VERILATOR_ONPATH) \
                                  $(VERILATOR_LOCAL)/bin/verilator)
# VERILATOR_UVM=1 (default) builds the full UVM testbench with Verilator:
# vendored UVM 1.2 + a .vlt waiver + --binary --timing. VERILATOR_UVM=0 just
# lints the synthesizable DUT.
VERILATOR_UVM  ?= 1
VERILATOR_LINT ?= 1
# Accellera UVM 1.2, auto-fetched (mirrors tt_hw_debug's Bazel http_archive:
# pinned URL + sha256 + strip_prefix). Downloaded/extracted under $(BUILD)/deps
# on first use; override UVM_ROOT to point at an existing copy.
UVM_VERSION    ?= 1.2
UVM_URL        ?= https://www.accellera.org/images/downloads/standards/uvm/uvm-$(UVM_VERSION).tar.gz
UVM_SHA256     ?= 502a2e605ce552bfd9767803c7e99a053715b00f7a9c4c511c3fbfddfb30157c
UVM_DEPDIR     ?= $(abspath $(BUILD)/deps)
UVM_ROOT       ?= $(UVM_DEPDIR)/uvm-$(UVM_VERSION)
# Optional Verilator lint waiver. The UVM build runs with -Wno-fatal, so a
# waiver is not required for the build to succeed -- it only quiets lint noise
# from the vendored C910 RTL. Pass it to Verilator ONLY if the file exists, so
# a missing waiver never aborts the build (it is not tracked in the repo).
VLT_WAIVER     ?= $(wildcard verilator_config.vlt)

# Self-contained Python config for the Verilator UVM flow: simv-vlt embeds
# libpython3.11, so the build/runtime Python MUST be the 3.11 venv (which has
# pysv etc.). Default everything to the local .venv so a plain
# `make run SIM=verilator VERILATOR_UVM=1 TEST=...` works regardless of the
# caller's shell python. Override on the command line if needed.
# Python 3.11 for the in-sim pysv/riescue page-table generator. The system
# default python3 is 3.6 (no pysv; riescue needs >=3.9) and simv-vlt embeds
# libpython3.11, so we use a 3.11 interpreter (system /usr/bin/python3.11 by
# default) with the required packages installed to its user site via pip
# (see the 'pydeps' target). No virtualenv required.
# Python interpreter for the in-sim pysv/riescue page-table generator. Needs
# >=3.9. Prefer python3.11 (matches the libpython the model embeds), else any
# python3 on PATH. Override with VLT_PY=/path/to/python3.
VLT_PY        ?= $(firstword $(shell command -v python3.11 python3 2>/dev/null))
# Package set for the in-sim page-table generator (single source of truth,
# pins pysv==0.3.1). Installed via 'pydeps'.
PY_REQS       ?= requirements.txt
ifeq ($(VERILATOR_UVM),1)
# Derive Python paths from the interpreter (portable). Requires the matching
# python3-dev/devel headers; if the sysconfig include dir has no Python.h, a
# site copy is tried before giving up. Override PY_INC/PY_SHLIB if needed.
PY_INC        ?= $(shell d=$$($(VLT_PY) -c "import sysconfig;print(sysconfig.get_path('include'))"); \
                   if [ -f "$$d/Python.h" ]; then echo "$$d"; \
                   elif [ -f /tools_vendor/FOSS/python3/include/python3.11/Python.h ]; then echo /tools_vendor/FOSS/python3/include/python3.11; \
                   else echo "$$d"; fi)
PY_SHLIB      ?= $(shell l=$$($(VLT_PY) -c "import sysconfig,os;print(os.path.join(sysconfig.get_config_var('LIBDIR') or '', sysconfig.get_config_var('INSTSONAME') or ''))"); \
                   if [ -f "$$l" ]; then echo "$$l"; else echo /usr/lib64/libpython3.11.so.1.0; fi)
# Derive from where pysv is installed, so this works for user-site OR venv.
PYBIND_INC    := $(shell $(VLT_PY) -c "import os,pysv;print(os.path.join(os.path.dirname(pysv.__file__),'extern'))" 2>/dev/null)
PY_SITE       := $(shell $(VLT_PY) -c "import os,pysv;print(os.path.dirname(os.path.dirname(pysv.__file__)))" 2>/dev/null)
endif

ifeq ($(VERILATOR_UVM),1)
#----- Full UVM testbench build + run -----
# Parallelism for Verilator's generated-C++ compile (large for UVM+RTL).
VERILATOR_JOBS ?= $(shell nproc)
# Waveforms: VERILATOR_WAVES=vcd | fst enables tracing in the build; then run
# with +wave [+wavefile=<path>]. Default off (tracing slows sim + build).
VERILATOR_WAVES ?=
ifeq ($(VERILATOR_WAVES),vcd)
VLT_TRACE_FLAGS = --trace
else ifeq ($(VERILATOR_WAVES),fst)
VLT_TRACE_FLAGS = --trace-fst
else
VLT_TRACE_FLAGS =
endif
# Runtime PYTHONPATH for the embedded interpreter (pysv/riescue pt-gen), same
# search path the VCS run uses.
VLT_RUN_PYTHONPATH = $(abspath scripts):$(abspath $(RIESCUE_DIR)):$(PY_SITE)

# A shim dir providing `python3` -> $(VLT_PY) (system default python3 may be
# too old), plus a newer g++ if available. Verilator's UVM build needs g++ >=10
# (-std=c++20, -fcoroutines); use gcc-toolset-11 when present (RHEL), otherwise
# rely on a sufficiently new system g++.
PYBIN_DIR := $(abspath $(BUILD)/pybin)
# Probed, not required: empty on any distro whose default g++ is already >= 10.
# Override for a toolchain installed elsewhere, e.g. GCC_TOOLSET_DIR=/opt/gcc-13/bin.
GCC_TOOLSET_DIR ?= /opt/rh/gcc-toolset-11/root/bin
GCC_TOOLSET := $(firstword $(wildcard $(GCC_TOOLSET_DIR)))
export PATH := $(PYBIN_DIR)$(if $(GCC_TOOLSET),:$(GCC_TOOLSET)):$(PATH)

# Fetch + verify + extract Accellera UVM (http_archive equivalent). Idempotent:
# skips work once $(UVM_ROOT)/src/uvm_pkg.sv exists.
# Ensure the 3.11 interpreter has the pysv/riescue packages (pip --user, no
# venv), and provide a `python3` shim so ptgen's `python3` is 3.11.
# Idempotent: only pip-installs if pysv is missing.
.PHONY: pydeps
pydeps:
	@mkdir -p $(PYBIN_DIR)
	@ln -sf "$(VLT_PY)" "$(PYBIN_DIR)/python3"
	@# Check every runtime import, not just pysv: guarding on one package meant
	@# deps added to requirements.txt later (z3-solver) were never installed.
	@if ! "$(VLT_PY)" -c "import pysv, z3, sortedcontainers, intervaltree" >/dev/null 2>&1; then \
	  echo "Installing Python deps for $(VLT_PY) from $(PY_REQS)"; \
	  "$(VLT_PY)" -m ensurepip --user >/dev/null 2>&1 || true; \
	  "$(VLT_PY)" -m pip install --user -r $(PY_REQS); \
	else \
	  echo "Python deps present for $(VLT_PY)"; \
	fi

# Clone + build Verilator locally under $(VERILATOR_HOME). Idempotent: skips
# once the verilator binary exists. Needs gcc-toolset-11 (g++11) and python3
# >=3.7, both prepended to PATH above.
.PHONY: verilator_build
verilator_build:
	@# Always build into VERILATOR_LOCAL, never VERILATOR_HOME: the latter is a
	@# caller-supplied install prefix, and cloning into it would write into the
	@# user's own directory.
	@if [ ! -x "$(VERILATOR)" ]; then \
	  echo "Building Verilator $(VERILATOR_VERSION) at $(VERILATOR_LOCAL)"; \
	  if [ ! -d "$(VERILATOR_LOCAL)/.git" ]; then \
	    git clone "$(VERILATOR_REPO)" "$(VERILATOR_LOCAL)"; \
	  fi; \
	  cd "$(VERILATOR_LOCAL)" && git checkout "$(VERILATOR_VERSION)" && \
	    autoconf && ./configure && $(MAKE) -j$(shell nproc); \
	  test -x "$(VERILATOR)" || { echo "ERROR: verilator build failed"; exit 1; }; \
	  echo "Verilator ready: $$($(VERILATOR) --version)"; \
	else \
	  echo "Verilator present: $$($(VERILATOR) --version)"; \
	fi

.PHONY: uvm_fetch
uvm_fetch:
	@if [ ! -f "$(UVM_ROOT)/src/uvm_pkg.sv" ]; then \
	  echo "Fetching UVM $(UVM_VERSION) from $(UVM_URL)"; \
	  mkdir -p "$(UVM_DEPDIR)"; \
	  cd "$(UVM_DEPDIR)"; \
	  ( command -v wget >/dev/null && wget -q "$(UVM_URL)" -O uvm-$(UVM_VERSION).tar.gz ) \
	    || curl -fsSL "$(UVM_URL)" -o uvm-$(UVM_VERSION).tar.gz; \
	  echo "$(UVM_SHA256)  uvm-$(UVM_VERSION).tar.gz" | sha256sum -c - \
	    || { echo "ERROR: UVM sha256 mismatch"; exit 1; }; \
	  tar xzf uvm-$(UVM_VERSION).tar.gz; \
	  test -f "$(UVM_ROOT)/src/uvm_pkg.sv" || { echo "ERROR: uvm_pkg.sv not found after extract"; exit 1; }; \
	  echo "UVM ready at $(UVM_ROOT)"; \
	else \
	  echo "UVM present at $(UVM_ROOT)"; \
	fi

compile: pydeps verilator_build uvm_fetch ptgen
	@mkdir -p $(BUILD)
	@echo "EXPERIMENTAL: building full UVM TB with Verilator (UVM $(notdir $(UVM_ROOT)))."
	$(VERILATOR) --binary --timing -sv -j $(VERILATOR_JOBS) \
	    $(VLT_LDFLAGS_OVERRIDE) \
	    $(VLT_TRACE_FLAGS) \
	    -Wno-fatal --error-limit 10000 \
	    --top-module $(TOP) \
	    -CFLAGS "-std=c++20 -DVL_TIME_CONTEXT" \
	    +define+UVM_NO_DPI +define+UVM_REGEX_NO_DPI \
	    +incdir+$(UVM_ROOT)/src $(UVM_ROOT)/src/uvm_pkg.sv \
	    $(VLT_WAIVER) \
	    -f $(FILELIST) \
	    $(abspath $(PYSV_DIR)/PageTableSV.o) $(abspath $(SYSMEM_OBJS)) $(abspath $(WHISPER_OBJ)) $(abspath $(DVMMU_LIB)) \
	    -LDFLAGS "-L$(dir $(PY_SHLIB)) -l:$(notdir $(PY_SHLIB)) -lpthread -ldl -lutil -lm -L/usr/lib64 -llz4" \
	    --Mdir $(BUILD)/obj_dir -o simv-vlt \
	    2>&1 | tee $(BUILD)/verilator.log

# Verilator implements SV randomize() via an external SMT solver (z3 by default).
# Needed for constrained-random (e.g. the +PT_DYNAMIC page-table config gen).
# Auto-discover z3: (1) on PATH, (2) the pip 'z3-solver' CLI in the Python
# user-base bin (installed by requirements.txt / pydeps).
# Override with VERILATOR_SOLVER=/path/to/z3.
VLT_PY_USERBIN := $(shell $(VLT_PY) -m site --user-base 2>/dev/null)/bin
VERILATOR_SOLVER ?= $(firstword $(shell command -v z3 2>/dev/null) \
                                $(wildcard $(VLT_PY_USERBIN)/z3))

run: compile run-only

# run-only: launch simv-vlt WITHOUT rebuilding. Mirrors the VCS run-only so the
# regression flow can build once and reuse the binary for every test target.
run-only:
	@mkdir -p $(RUNDIR)
	@if [ ! -x "$(BUILD)/obj_dir/simv-vlt" ]; then \
	  echo "run-only: $(BUILD)/obj_dir/simv-vlt not found — build first with 'make compile SIM=verilator VERILATOR_UVM=1'"; exit 1; fi
	@[ -n "$(VERILATOR_SOLVER)" ] || echo "WARNING: no z3/SMT solver found; SV randomize() (e.g. +PT_DYNAMIC) will fail. Set VERILATOR_SOLVER=/path/to/z3."
	@# Redirect (do NOT pipe through tee): the embedded Python (pysv/riescue)
	@# writes on its own buffered fd, so with `2>&1 | tee` two independent
	@# writers share one pipe and can interleave MID-LINE, shredding the UVM
	@# summary (e.g. "UVM_ERR<enum 'DataType'>...") and making a clean run look
	@# like a crash to the pass/fail gate below. A plain redirect gives each fd
	@# a single destination. PYTHONUNBUFFERED keeps Python from holding partial
	@# lines. Console tail is echoed after the run.
	unset PYTHONHOME; export PYTHONPATH="$(VLT_RUN_PYTHONPATH)"; \
	export PYTHONUNBUFFERED=1; \
	export VERILATOR_SOLVER="$(VERILATOR_SOLVER) --in"; \
	export PATH="$(dir $(VERILATOR_SOLVER)):$$PATH"; \
	$(BUILD)/obj_dir/simv-vlt +UVM_TESTNAME=$(TEST) \
	    $(RUN_PLUSARGS) \
	    > $(RUNDIR)/run.log 2>&1 || true
	@# Replay the whole transcript to stdout so the caller's log (e.g. the
	@# regression per-target log) is a SUPERSET of run.log -- matching the VCS
	@# flow, where `simv -l run.log` both writes the file and prints to stdout.
	@# Deliberately a post-run `cat`, not `| tee`: piping live would let the
	@# embedded Python (pysv/riescue) interleave mid-line with the UVM output
	@# and shred the "UVM_ERROR :" summary line the gate below parses.
	@cat $(RUNDIR)/run.log
	@# Gate pass/fail on the UVM report (same policy as the VCS flow) so the
	@# regression launcher sees a non-zero exit on UVM_ERROR/UVM_FATAL/crash.
	@log="$(RUNDIR)/run.log"; \
	full="$(abspath $(RUNDIR))/run.log"; \
	errc=$$(sed -nE 's/.*UVM_ERROR :[[:space:]]+([0-9]+).*/\1/p' "$$log" | tail -1); \
	fatc=$$(sed -nE 's/.*UVM_FATAL :[[:space:]]+([0-9]+).*/\1/p' "$$log" | tail -1); \
	if [ -z "$$errc" ] || [ -z "$$fatc" ]; then \
	  echo "RUN FAIL: $(TEST) (no UVM report summary in run.log — crashed?)"; \
	  echo "FULL LOG: $$full"; exit 1; \
	elif [ "$$fatc" != "0" ] || [ "$$errc" != "0" ]; then \
	  echo "RUN FAIL: $(TEST) (UVM_ERROR=$$errc UVM_FATAL=$$fatc)"; \
	  echo "FULL LOG: $$full"; \
	  echo "--- first 20 UVM_ERROR/UVM_FATAL lines ---"; \
	  grep -E "UVM_(ERROR|FATAL)" "$$log" | grep -vE "UVM_(ERROR|FATAL) :" | head -20; \
	  exit 1; \
	else \
	  echo "RUN PASS: $(TEST) (UVM_ERROR=0 UVM_FATAL=0)"; \
	fi
else
#----- RTL-only lint/elaborate (no UVM) -----
VERILATOR_TOP  ?= ct_mmu_top
VERILATOR_INCDIRS = \
    +incdir+rtl/openc910/C910_RTL_FACTORY/gen_rtl/mmu/rtl \
    +incdir+rtl/openc910/C910_RTL_FACTORY/gen_rtl/cpu/rtl
ifeq ($(VERILATOR_LINT),1)
VERILATOR_MODE = --lint-only
else
VERILATOR_MODE = --binary --timing
endif

compile:
	@mkdir -p $(BUILD)
	@echo "NOTE: RTL-only Verilator (no UVM); linting DUT top '$(VERILATOR_TOP)'."
	@echo "      For the UVM TB set VERILATOR_UVM=1 (experimental)."
	@# filelist.f mixes DUT RTL and the UVM TB. Extract the DUT-only section
	@# (everything before the "// Testbench" marker) for Verilator.
	@sed '/\/\/ Testbench/,$$d' $(FILELIST) > $(BUILD)/rtl_filelist.f
	$(VERILATOR) $(VERILATOR_MODE) -sv -Wno-fatal \
	    --top-module $(VERILATOR_TOP) \
	    $(VERILATOR_INCDIRS) \
	    -f $(BUILD)/rtl_filelist.f \
	    2>&1 | tee $(BUILD)/verilator.log

run: compile
	@echo "SIM=verilator (RTL-only): UVM run not built. Use VERILATOR_UVM=1, or SIM=vcs."
endif
endif

clean:
	rm -rf $(BUILD) csrc simv* *.log *.vpd *.fsdb ucli.key vc_hdrs.h
	rm -f generated_pt_output*.json whisper.log
	-$(MAKE) -C $(DVMMU_DIR) clean 2>/dev/null   # submodule build artifacts (libdvmmu.a, *.o/.d)
