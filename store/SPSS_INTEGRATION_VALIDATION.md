# Licensed IBM SPSS Windows Validation Gate

This gate cannot run in public CI because the repository does not contain or
grant an IBM SPSS Statistics licence. It must be completed by authorised testers
in two distinct x64 Windows environments before the protected GitHub release
environment is approved.

## Scope and timing

Each reviewer-approved private assertion records the exact immutable release **tag commit**, committed
synthetic fixture, SPSS integration-source digest, and one identical private
Windows layout-manifest SHA-256 tested in both environments. It does not claim that a
later RFC-3161-signed GitHub EXE or Partner Center MSIX was installed in the
licensed environment. The public installer is built and signed only after both
records pass the protected assertion gate, so such a package claim would have
the wrong time order.

Run this on the exact tag commit to obtain the binding values:

```powershell
python ./scripts/verify_spss_release_attestations.py `
  --repo . `
  --tag windows-v1.1.0 `
  --commit <40-character-peeled-tag-commit> `
  --app-version 1.1.0 `
  --print-context
```

## Required private evidence per environment

1. Record a pseudonymous environment ID, Windows edition/version/build/x64,
   IBM SPSS Statistics version, Python integration version, and confirmation
   that the tester is authorised to use the licence. Never record a key,
   credential, IBM ID, or identifying workstation path.
2. Build one private Windows layout from the exact tag commit. Run
   `Write-ArtifactHashes.ps1` over that candidate, hash its resulting
   `SHA256SUMS.txt`, and record this as `testedCandidate.sha256` with kind
   `private-windows-layout-manifest`. Use that exact layout manifest in both
   licensed environments. Confirm it detects external `statisticspython3.bat`
   without copying IBM files into the application. This private layout is not
   the later timestamp-signed public installer or Partner Center package.
3. Run `examples/synthetic_survey.csv` with formal execution enabled, restart the
   application, and repeat the formal run.
4. Confirm the completion marker has `status=complete`; `analysis_data.sav`
   passes bounded full `pyreadstat` parsing, `analysis_output.spv` passes bounded
   complete ZIP read/CRC checks, and `analysis_output.pdf` passes bounded strict
   structural and stream decoding. Record this as per-run **format integrity**.
5. Compare the generated syntax/results with a manual IBM SPSS run. Record the
   number of compared values, tolerance, and maximum absolute delta separately
   for descriptives, reliability, correlations, factorability, and regression.
   Every delta must be within its declared tolerance, and tolerance cannot exceed
   `1e-4`.
6. Hash the complete private evidence bundle with SHA-256. Keep screenshots,
   logs, result tables, and any candidate hashes private; they are never Actions
   artifacts or release assets.
7. Repeat all steps in a second environment with a distinct environment ID and
   Windows fingerprint. The two evidence hashes must also differ.

## Structured reviewer-approved private assertion

Create one JSON object per environment that conforms exactly to
[`spss-validation-attestation.schema.json`](spss-validation-attestation.schema.json).
The historical schema filename is retained for compatibility; the JSON title,
field names, verifier output, and release claims define these as private
assertions, not attestations.
The strict verifier rejects missing/extra/duplicate fields, reused environments,
future/old records, non-finite statistics, weakened tolerances, mismatched tag,
commit, fixture or integration hashes, different private layout-manifest hashes,
and any scope that claims an exact signed installer/MSIX.

Protect each raw JSON record with HMAC-SHA256 using a randomly generated
minimum-256-bit key. This shared HMAC can detect a changed record inside the
protected review environment, but it cannot establish two independent tester
identities, verify the self-declared Windows/SPSS facts, or replace human review.
Store the JSON records, lowercase HMACs, and base64 key only as secrets in the
reviewer-protected GitHub Environment `trusted-windows-release-spss-review`:

- `SPSS_ASSERTION_1_JSON`
- `SPSS_ASSERTION_1_HMAC_SHA256`
- `SPSS_ASSERTION_2_JSON`
- `SPSS_ASSERTION_2_HMAC_SHA256`
- `SPSS_ASSERTION_HMAC_KEY_BASE64`

Set environment variable `SPSS_RELEASE_VALIDATION_APPROVED=true` and
`SPSS_RELEASE_VALIDATED_TAG=windows-v1.1.0` only after an authorised reviewer has
checked both private bundles. Do not print these secrets or attach them to a PR.
The trusted release build also recomputes `SHA256(SHA256SUMS.txt)` and requires
it to equal the `testedCandidate.sha256` returned by both approved assertions;
matching two assertions to each other without matching the built candidate is
not sufficient. Do not approve the review job until the build job has staged its
exact private handoff and both authorised environments have tested those bytes.
The review job runs under a distinct review-gate account, then atomically removes
all writers and transfers the frozen layout read-only to the sign-only domain.

## Required negative tests

- No IBM SPSS installation: formal toggle disabled and preview path succeeds.
- Installed but unlicensed/activation blocked: no verified-success state and no
  partial SAV/SPV/PDF files in the downloadable bundle.
- Driver returns non-zero, marker missing/corrupt/failed, one output missing, or
  timeout: fail closed, confirm process-tree termination, and preserve only
  previews/supporting files.
- SPSS launcher and job paths containing Chinese characters, spaces, and an
  apostrophe (for example `来泽宇 O'Brien`) still launch and preserve the exact
  completion-marker path.
- Parentheses remain supported inside the quoted `/v:off` arguments. Paths with
  `%`, `!`, `&`, `<`, `>`, `^`, `|`, a double quote, CR, or LF are rejected
  before `cmd.exe` starts because a vendor batch file can reparse expanded
  arguments and quoting alone cannot make those characters generally safe.
- Magic-only, truncated, oversized, corrupt, or decompression-bomb SAV/SPV/PDF
  outputs fail. A correctly encoded empty Flate PDF stream remains valid.
- App restart during a job: job becomes interrupted/failed, never complete.

## Sign-off

- Tester 1: pending
- Tester 2: pending
- Date: pending
- Environment 1: pending
- Environment 2: pending
- Protected evidence location: pending
- Format integrity parser implementation: implemented; authorised run pending
- Two-environment statistical semantic result: **NOT YET VERIFIED**
