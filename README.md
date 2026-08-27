# Survey Data Workbench by LAI ZEYU

> Requires a separately installed and licensed IBM SPSS Statistics for optional
> formal SPSS execution. The preview workflow works without IBM SPSS.

Survey Data Workbench by LAI ZEYU is an independently developed, local survey
analysis application. It imports research datasets, detects multi-item
constructs, generates reproducible Python previews and SPSS syntax, and can
optionally invoke a user's own licensed IBM SPSS Statistics installation.

Author / 开发者: **LAI ZEYU（来泽宇）**.

The product is not an IBM product and is not affiliated with, endorsed by, or
sponsored by IBM. IBM and SPSS are trademarks of International Business
Machines Corporation in many jurisdictions.

## Execution provenance

The application deliberately separates two modes:

1. **Python preview** generates diagnostic CSV tables, JSON, a Chinese summary,
   SPSS syntax, and a ZIP bundle. These are not represented as formal IBM SPSS
   output.
2. **Optional IBM SPSS execution** uses vendor-provided Python integration from
   a separately installed and licensed environment. Success is reported only
   when a trusted completion marker is present, SAV parses with `pyreadstat`,
   SPV is a complete readable ZIP container, and PDF passes structural parsing.
   Partial or magic-only pseudo-files are removed from the bundle. This is a
   per-run **format-integrity** gate, not statistical-semantic certification.

Installation detection or format integrity alone never proves that an IBM
licence, integration, or statistical result is valid. Release-level semantic
validation remains a separate two-authorised-environment gate.

## Features

- Imports `.xlsx`, `.xls`, `.xlsm`, `.csv`, `.tsv`, `.txt`, `.sav`, `.zsav`, and `.por`.
- Rejects files over 100 MB, oversized row/column/cell counts, unsafe or
  high-ratio XLSX/ZIP structures, and column names that collide after trimming
  or case folding.
- Detects constructs from item names such as `FQ1`, `FQ2`, and `PU_3`.
- Supports descriptive statistics, Cronbach's alpha, correlations, exploratory
  factor-analysis preparation, and multiple linear regression.
- Stores uploads and outputs in private application data, not the installation directory.
- Uses a configurable 1–3,650 day retention period and in-app deletion.
- Runs the packaged API on a random `127.0.0.1` port with a per-launch token,
  Host/Origin checks, Fetch Metadata checks, CSP, and other security headers.
- Provides a .NET 8 WPF/WebView2 shell, PyInstaller sidecar, and x64 MSIX build path.

## Architecture

```text
.NET 8 WPF + WebView2
          |
          | random loopback port + per-launch token
          v
Waitress + Flask application factory
          |
          +-- pandas / NumPy preview and reproducible files
          |
          +-- cross-platform SPSS runner abstraction
                    |
                    +-- Windows: external statisticspython3.bat driver
                    +-- macOS: embedded-Python syntax automation
```

IBM binaries, Python integration files, licences, credentials, and activation
material are never bundled.

## Development verification

Requirements: Python 3.10+ (3.12 reference), Node.js 20+ (22 reference), and npm.

```bash
./scripts/verify.sh
```

Or run the gates directly:

```bash
python -m pip install -r requirements.lock.txt
python -m pip install pip-audit==2.10.1
python scripts/check_attribution.py
python -m pip_audit -r requirements.lock.txt
python -m pip_audit -r requirements-build.txt
python -m unittest discover -s tests -v
cd frontend
npm ci
npm audit
npm run build
```

`scripts/verify.sh` does not require IBM SPSS and must not be described as a
licensed-integration test.

## Windows build

On x64 Windows with Python 3.12.10, Node.js 22.18.0, .NET SDK 8.0.424,
.NET runtime 8.0.30, and the Windows SDK:

```powershell
./scripts/Build-Windows.ps1 -Configuration Release -Architecture x64
./scripts/Test-WindowsSidecar.ps1 -LayoutDirectory ./artifacts/windows-x64/layout
./scripts/Build-Msix.ps1 -LayoutDirectory ./artifacts/windows-x64/layout -Development
```

`-Development` creates an unsigned local-only package. The Store product is reserved
as Store ID `9NWXQZP2ZG2H`, Identity `LAIZEYU.SurveyDataWorkbenchbyLAIZEYU`,
technical Publisher `CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8`, and Publisher display
name `LAI ZEYU`. Production packaging hard-locks all three identity values; bilingual
`LAI ZEYU（来泽宇）` authorship remains visible in the product description, About
surface, listing, licence, and compiled metadata. For example:

```powershell
./scripts/Build-Msix.ps1 `
  -LayoutDirectory ./artifacts/windows-x64/layout `
  -IdentityName "LAIZEYU.SurveyDataWorkbenchbyLAIZEYU" `
  -Publisher "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8" `
  -PublisherDisplayName "LAI ZEYU"
```

These are the values copied from the reserved Partner Center product. See
[`store/STORE_SUBMISSION_CHECKLIST.md`](store/STORE_SUBMISSION_CHECKLIST.md).
`Build-Msix.ps1` emits the Partner Center package unsigned by default. The
repository never uploads that unsigned MSIX, its EXE/DLL layout, or an archive
containing them as a GitHub Actions artifact. The protected Store path transfers
the exact hash-manifest-bound candidate only through a pre-provisioned private
UNC share with principal-specific ACLs. If Partner Center's technical Publisher
differs from the personal code-signing certificate Subject, keep the Store MSIX
on the Partner Center ingestion path and publish the separately signed EXE
installer on GitHub.

## Privacy

The application itself has no account, advertising, application telemetry, or
developer-operated cloud upload. Uploads, job configuration, outputs, settings,
rotating local logs, and WebView2 support data stay in application data. The
in-app task-data control deletes uploads, job configurations, previews, and
outputs; it does not reset preferences or support data. Users remain responsible
for lawful handling and de-identification of respondent data. The effective
policy is in [`store/PRIVACY_POLICY.md`](store/PRIVACY_POLICY.md) and its stable
public URL is recorded in the Store submission checklist. Partner Center entry
of that URL remains an explicit external submission gate.

## Current release gates

- Cross-platform Python/API tests and frontend builds can run without IBM SPSS.
- Hosted Windows source gates run twice and upload no artifact. A separate
  protected, organisation runner-group job may build the reserved-identity Store
  candidate only from the exact current protected `main`, then place it on a
  principal-specific private ACL share. The pinned ACL harness transfers that
  handoff to a non-login owner, makes builder/Windows 10/Windows 11 identities
  read-only, and reserves read/delete-only access for a separate cleanup account.
  Because the present personal repository
  cannot supply those organisation runner groups, privileged jobs fail closed.
- A default-branch `workflow_run` re-resolves repository ID, workflow ID, run
  attempt, and exact current `main` before two protected interactive/elevated
  Windows 10 and Windows 11 runner groups may read the private candidate. Each
  runner creates one non-exportable temporary QA signature and uses that exact
  signed MSIX for two sequential WACK/lifecycle passes. The WACK executable hash,
  file version, and report version must equal protected environment approvals.
  Each pass requires a fresh complete XML `PASS`, exact external product window
  title, exactly one sidecar loopback listener, safe PID/path/creation/parent
  ownership, relaunch, uninstall, and `LocalState` removal. No production binary
  contains an in-app CI evidence/DOM automation path.
- Only after both private pass steps succeed may each OS job upload two public
  files: fixed-schema `windows-gate-summary.v3.json` and its SHA-256 manifest.
  The summary binds the repository, build and review workflow run IDs/attempts,
  exact commit/private handoff digest, approved WACK tool identity, and hashes of
  the private lifecycle JSON and WACK XML. It excludes raw reports, XML,
  filesystem paths, binaries, packages, certificates, and keys, and explicitly
  identifies itself as a same-workflow assertion rather than an independent or
  non-forgeable attestation.
- That strict Windows workflow is implemented but is not evidence until it is
  green on the selected commit. Clean Windows 10/11 update/repair,
  accessibility, WebView2-absent recovery, the final Partner Center-associated
  package, and Store certification remain external gates.
- Licensed IBM SPSS validation remains **NOT YET VERIFIED** until the procedure
  in [`store/SPSS_INTEGRATION_VALIDATION.md`](store/SPSS_INTEGRATION_VALIDATION.md)
  is completed twice on authorised Windows environments.
- The only supported GitHub binary publication path is the manual trusted-release
  workflow. It publishes one EXE installer, not a second Store MSIX. Two
  reviewer-approved private IBM SPSS assertions bind the selected tag commit,
  fixture, integration-source digest, and exact private layout manifest. Their
  shared HMAC is integrity-only inside one protected environment: it does not
  establish independent tester identities, prove the self-declared environment
  facts, or claim that the later signed installer/MSIX ran in SPSS.
- Release build, licensed-SPSS review, clean sign-only, independent lifecycle
  verification, no-checkout publication, and least-privilege cleanup use
  distinct protected organisation runner groups and accounts; no unsigned
  EXE/DLL/MSIX is uploaded to Actions. A pinned ACL harness atomically changes
  each private handoff owner and exact grants, removes the previous writer,
  rechecks reparse points and hashes, and gives the cleanup identity delete/read
  rights rather than persistent Full Control. The signing domain accepts only a pinned,
  timestamp-signed, out-of-repository harness and never launches a repository-derived
  EXE or DLL. That harness must obtain the
  reusable SSL.com eSigner secret through a machine-bound broker rather than a
  command-line TOTP seed, verify provider/key-container cleanup, and produce a
  real recursive PE inventory. Every nested PE, signed uninstaller, and final EXE
  must have one identical `LAI ZEYU`/`来泽宇` certificate thumbprint, SHA-256
  signature, RFC 3161 timestamp, and timestamp EKU. Only after complete broker,
  provider, and key-container cleanup are the frozen signed bytes transferred to
  a separate verifier account that has no signing credential; that account runs
  two complete lifecycle passes on the identical installer bytes and binds the
  exact installed executable, PID/listener, and uninstall cleanup state.
- The no-checkout publisher receives only the frozen verifier-approved handoff and
  receives the GitHub token only in its REST publication
  step, re-resolves the exact current `main` and peeled tag, accepts ownership only
  from a successful HTTP 201 response with a numeric Release ID, never adopts an
  ambiguous create, validates exact asset IDs/digests before and after public
  redownload, and rolls back only the owned numeric ID to draft. These external
  runner groups, protected environments, signing harness/certificate, and private
  SPSS assertions are not configured yet, so no GitHub Windows binary is currently
  published. The technical Partner Center Publisher CN remains a system identity,
  never the author.

## Licence and author

Released under the [MIT License](LICENSE).

Developed independently by **LAI ZEYU（来泽宇）**, Business Administration undergraduate,
Universiti Kebangsaan Malaysia. GitHub: [lzy2767865503-pixel](https://github.com/lzy2767865503-pixel)
