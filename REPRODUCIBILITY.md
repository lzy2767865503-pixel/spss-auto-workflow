# Reproducibility Guide

This project separates what anyone can verify from the parts that depend on
licensed IBM software. No private dissertation data, respondent records, API
keys, or IBM software are required for the self-contained checks.

## Reference Environment

- Windows 10 22H2 or Windows 11 x64 for the packaged desktop/MSIX path
- macOS 13 or newer for the legacy automatic IBM SPSS launching path
- Python 3.12.10 for the Windows candidate (application minimum: Python 3.10)
- Node.js 22.18.0 for the Windows candidate (application minimum: Node.js 20)
- .NET SDK 8.0.424 and self-contained runtime 8.0.30 for Windows
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
2. installs and audits the locked runtime/build Python dependencies;
3. runs the bilingual attribution gate and the backend analysis/Flask API tests against
   `examples/synthetic_survey.csv`;
4. installs and audits the exact frontend dependency tree with `npm ci`;
5. creates the Vite production build.

Expected result: all Python tests pass and `frontend/dist/index.html` exists.

## Level 2: Local Python Preview

Run the application:

```bash
./start.command
```

The launcher chooses a random loopback port, creates a per-launch token, and
opens the authenticated local URL. Upload `examples/synthetic_survey.csv` and
inspect the detected constructs. Without
IBM SPSS, the application remains usable in **Python preview mode**: it
prepares data, generates SPSS syntax, produces diagnostic tables, and creates a
download bundle.

The Python calculations are explicitly labelled previews, not verified IBM
SPSS formal output.

Each result bundle also contains a portable SPSS template and
`prepare_portable_spss_run.py`. After moving a bundle to another machine, run
that helper inside the extracted folder before opening
`run_with_spss_python_portable.sps`. This removes the original machine's
absolute job path from both the embedded-Python marker literal and the
JSON-escaped SPSS command string. Unicode, spaces, apostrophes, and parentheses
are retained and the marker is relocated to the extracted directory.

## Level 3: Licensed IBM SPSS Execution

Official `.sav`, `.spv`, and exported PDF outputs require:

- a locally installed and activated IBM SPSS Statistics application;
- an SPSS version that supports vendor-provided Python integration and `spss.Submit()`;
- on Windows, a detected `statisticspython3.bat` and external Python runtime;
- macOS Accessibility permission when automatic menu control is used.

If SPSS is installed outside the default application path:

```bash
SPSS_APP_PATH="/Applications/IBM SPSS Statistics/IBM SPSS Statistics.app" \
./start.command
```

IBM SPSS Statistics and its licence are not distributed with this repository.
The automatic preflight checks installation paths; it does not certify the SPSS
version, Python integration, or licence state. Licensed end-to-end execution is
environment-specific and is not asserted by the open-source CI. The app reports
format-integrity success only after the completion marker plus full SAV, SPV,
and PDF parsers all pass. This does not replace semantic comparison in two
independent authorised IBM SPSS environments.

## Data and Result Integrity

- The committed example is synthetic and contains no real respondents.
- Generated jobs remain under the application's private local data directory.
- Do not commit `.sav`, `.spv`, respondent-level data, or confidential outputs.
- Record the operating system, Python version, Node.js version, SPSS version,
  selected variables, and generated job metadata when reporting results.

## Continuous Integration

GitHub Actions runs cross-platform validation and a private Windows candidate
workflow. Hosted source gates run twice and upload no artifact. Only an approved
organisation runner group and protected environment may build the WPF,
PyInstaller, and reserved-identity Store candidate from the exact current
protected `main`. It records every regular non-reparse candidate file in
`SHA256SUMS.txt`, verifies the manifest twice, and moves the candidate only to a
pre-provisioned principal-specific private ACL share. The current personal
repository has no such runner groups, so this stage fails closed.

A default-branch `workflow_run` independently re-resolves the stable repository
ID, exact upstream workflow/run/attempt, and exact current `main`. Protected,
interactive, elevated Windows 10 and Windows 11 runner groups then copy the
private candidate locally. A pinned ACL harness has already atomically moved the
handoff to a non-login owner with no writer; builder and both verifier identities
are read-only and an isolated cleanup account has only read/delete rights. Each runner signs one temporary non-exportable QA
MSIX exactly once and feeds the identical signed bytes to two sequential passes.
Each pass runs the protected-approved exact `appcert.exe` bytes (`reset`, then
package-path `test`), rejects a stale/missing/partial/non-`PASS` report, verifies
the external WPF title and one loopback sidecar listener, checks process
name/path/creation/parent identity, force-terminates WPF, verifies Job Object and
watchdog cleanup, relaunches, uninstalls the exact PackageFullName, and confirms
`LocalState` removal. Production binaries contain no CI evidence-request, DOM
automation, or evidence-upload feature.

After a private pass succeeds, a fixed-schema generator hashes its sidecar JSON,
lifecycle JSON, and WACK XML, and binds them to the build and review workflow
run IDs/attempts, exact commit/private handoff, OS evidence label, approved WACK
hash/version, and identical QA MSIX. Only `windows-gate-summary.v3.json` and its
SHA-256 manifest are made read-only and uploaded. Raw XML/logs, filesystem paths,
layouts, EXE, DLL, MSIX, certificates, PFX/key material, and archives are never
uploaded. The public JSON explicitly states that it is a same-workflow assertion,
not an independent or non-forgeable attestation.

A green workflow verifies the development identity on the hosted Windows
environment. It does not claim that a proprietary IBM SPSS licence, final
Partner Center identity, clean Windows 10/11 manual matrix, or Store
certification was available.

The separate trusted GitHub release workflow publishes an EXE installer rather
than reusing the Partner Center MSIX identity. Two reviewer-approved private SPSS
assertions bind licensed semantic comparisons to the immutable tag commit,
integration-source digest, and one exact private Windows layout-manifest SHA-256.
Their shared HMAC is an integrity check inside the protected review environment;
it does not prove two independent identities or any self-declared machine fact.

Build, licensed-SPSS review, sign-only, independent lifecycle verification,
publication, and cleanup use separate protected organisation runner groups and
accounts. A pinned external ACL harness atomically transfers every handoff to an
exact owner/grant set, removes the previous writer, forbids broad principals and
reparse points, and leaves only a separate delete/read cleanup identity. The signing,
verifier, and publisher jobs check out no repository code. The signing domain
invokes only a pinned, timestamp-signed, out-of-repository harness and is forbidden
from launching repository-derived EXE/DLL bytes; reusable SSL.com CKA credentials are obtained through
a machine-bound broker and never passed as a command-line TOTP seed. The harness
must restore provider/key-container baselines and emit a complete recursive PE
inventory proving one exact LAI signer thumbprint, one SHA-256 signature, RFC
3161 timestamp, and timestamp EKU for every nested PE, signed uninstaller, and
final installer. After the broker/provider/key cleanup is complete, an independent
account with no signing private key runs two full install/launch/PID-listener/
uninstall-cleanup passes on the same installer bytes and freezes a new publisher
handoff. The publisher gets `GH_TOKEN` only for its REST step, binds exact current `main` and
the peeled tag, never adopts an ambiguous create, and rolls back only the numeric
Release ID returned by a verified HTTP 201. No PFX or exportable production key
is used.
