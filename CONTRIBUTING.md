# Contributing to tt-riscv-mmu-tb

Thank you for your interest in contributing. This document explains how to
report problems and submit changes.

## Code of Conduct

This project adheres to the [Contributor Covenant](CODE_OF_CONDUCT.md). By
participating, you are expected to uphold this code. Please report unacceptable
behavior to **ospo@tenstorrent.com**.

## Reporting Bugs

Report bugs by opening a **GitHub Issue**. A good report includes:

- The test and command line used (e.g. `make run TEST=mmu_ifu_test +PT_DYNAMIC +PT_SEED=7`).
- The simulator and version (VCS or Verilator).
- The seed (`+PT_SEED=`) and, where possible, the generated
  `generated_pt_config.json` / `generated_pt_output.json` for the failing run.
- Expected vs. actual behavior, and the relevant excerpt from `run.log`.

Please do **not** file security vulnerabilities as public issues — see
[SECURITY.md](SECURITY.md).

## Submitting Changes

Bug fixes and new functionality are submitted via **Pull Requests**:

1. Create a branch for your change.
2. Keep the change focused; unrelated changes should be separate PRs.
3. Ensure the affected tests pass locally before opening the PR (see the
   "Running tests" and "Smoke and regression" sections of the [README](README.md)).
4. Open a Pull Request against the default branch with a clear description of
   the motivation and the testing performed.

Pull requests are reviewed on a **weekly** cadence. A maintainer may request
changes before merging. Merges use **squash** only.

## Project-Specific Requirements

- **License headers:** Every Tenstorrent-authored source file must carry an
  SPDX header:
  ```
  // SPDX-License-Identifier: Apache-2.0
  // SPDX-FileCopyrightText: 2026 Tenstorrent USA, Inc.
  ```
  Do not add or modify headers on third-party sources (e.g. `rtl/openc910`,
  `external/`, `third_party/`); retain their upstream headers unchanged.
- **DUT-agnostic layering:** The agent layer, page-table generator,
  reference-model comparison, and scoreboard are intended to be DUT-agnostic.
  Keep anything specific to the example DUT (OpenC910) behind the existing
  virtual seams rather than threading it through the shared environment.
- **Testing:** New checkers or stimulus should come with a test (or regression
  list entry) that exercises them, and should be scored against the Whisper
  reference model where applicable.
- **Style:** Match the conventions of the surrounding code.

## License

By contributing, you agree that your contributions will be licensed under the
[Apache License 2.0](LICENSE), consistent with the rest of the project.
