# Reproducibility Guide

This project separates what anyone can verify from the parts that depend on
licensed IBM software. No private dissertation data, respondent records, API
keys, or IBM software are required for the self-contained checks.

## Reference Environment

- macOS 13 or newer for automatic IBM SPSS launching
- Python 3.12 (application minimum: Python 3.9)
- Node.js 22 (application minimum: Node.js 20)
- npm with the committed `frontend/package-lock.json`

The Python dependency policy is declared in `requirements.txt` and the resolved
environment in `requirements.lock.txt`. The frontend tree is locked and must
be installed with `npm ci`.

## Level 1: Self-Contained Verification

From a fresh clone:

```bash
chmod +x scripts/verify.sh
./scripts/verify.sh
```

This command:

1. creates `.venv` if needed;
2. installs the Python dependencies;
3. runs the backend analysis and Flask API tests against
   `examples/synthetic_survey.csv`;
4. installs the exact frontend dependency tree with `npm ci`;
5. creates the Vite production build.

Expected result: all Python tests pass and `frontend/dist/index.html` exists.

## Level 2: Local Python Preview

Run the application:

```bash
./start.command
```

Open `http://127.0.0.1:8765`, upload
`examples/synthetic_survey.csv`, and inspect the detected constructs. Without
IBM SPSS, the application remains usable in **Python preview mode**: it
prepares data, generates SPSS syntax, produces diagnostic tables, and creates a
download bundle.

The Python calculations are diagnostics, not a substitute for official SPSS
inferential output.

Each result bundle also contains a portable SPSS template and
`prepare_portable_spss_run.py`. After moving a bundle to another Mac, run that
helper inside the extracted folder before opening
`run_with_spss_python_portable.sps`. This removes the original machine's
absolute job path from the rerun workflow.

## Level 3: Licensed IBM SPSS Execution

Official `.sav`, `.spv`, and exported PDF outputs require:

- a locally installed and activated IBM SPSS Statistics application;
- an SPSS version that supports embedded Python and `spss.Submit()`;
- macOS Accessibility permission when automatic menu control is used.

If SPSS is installed outside the default application path:

```bash
SPSS_APP_PATH="/Applications/IBM SPSS Statistics/IBM SPSS Statistics.app" \
./start.command
```

IBM SPSS Statistics and its licence are not distributed with this repository.
The automatic preflight checks the configured macOS application and binary
paths; it does not certify the SPSS version, embedded-Python availability, or
licence state. Licensed end-to-end execution is environment-specific and is not
asserted by the open-source CI. If automatic macOS menu control is unavailable,
open the generated `.sps` file and choose **Run > All** manually.

## Data and Result Integrity

- The committed example is synthetic and contains no real respondents.
- Generated jobs remain under the ignored `data/jobs/` directory.
- Do not commit `.sav`, `.spv`, respondent-level data, or confidential outputs.
- Record the operating system, Python version, Node.js version, SPSS version,
  selected variables, and generated job metadata when reporting results.

## Continuous Integration

GitHub Actions runs Level 1 on every push and pull request. A green workflow
verifies the open-source portion only; it does not claim that a proprietary IBM
SPSS licence was available in CI.
