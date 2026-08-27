# Microsoft Store Submission Checklist

This repository can produce an x64 development MSIX, but a Store submission is
not authorised or complete until every unchecked external gate below is closed.

## Repository gates

- [x] Independent product name: **Survey Data Workbench by LAI ZEYU**.
- [x] Exact bilingual developer attribution `LAI ZEYU（来泽宇）` is enforced by `scripts/check_attribution.py`.
- [x] x64 .NET 8 WPF shell using Microsoft Edge WebView2.
- [x] Python sidecar packaged with PyInstaller; random loopback port and per-launch token.
- [x] Uploads and outputs stored outside the read-only installation directory.
- [x] User-configurable retention period and accurately scoped in-app deletion of uploaded datasets, job configurations, previews, and outputs.
- [x] Python preview, per-run IBM SPSS file-format integrity, and two-environment statistical-semantic validation are three separate states.
- [x] IBM software, Python integration components, and licences are not bundled.
- [x] Hosted source gates upload no artifact. Only a protected organisation runner-group job may build one exact-current-`main` reserved-identity candidate and transfer it through a principal-specific private ACL share; the current personal repository fails closed.
- [x] Separate protected interactive/elevated Windows 10 and Windows 11 runner groups each reuse one temporary-signed QA MSIX byte-for-byte for two sequential passes.
- [x] The two-pass implementation verifies the external exact product window title, one loopback listener, PID/name/executable-path/creation/parent identity, protected-approved WACK executable hash/version, fresh complete XML `PASS`, forced-exit cleanup, relaunch, exact PackageFullName uninstall, and `LocalState` removal. Production binaries contain no CI evidence/DOM automation feature.
- [x] Public Actions evidence is limited to fixed-schema JSON plus SHA-256 after a successful private pass. It binds build/review run IDs and attempts, exact commit/private candidate, approved WACK identity, and hashes of private lifecycle/WACK evidence; raw logs/XML/filesystem paths and all binaries/packages/certificates/keys are excluded. It states that it is same-workflow evidence, not independent cryptographic proof.
- [ ] CI must pass on the exact commit selected for release.
- [ ] Install/uninstall/update/repair must pass twice on clean Windows 10 22H2 and Windows 11 x64 virtual machines.
- [ ] Windows App Certification Kit must pass on the release package.

## Partner Center gates

- [x] Reserve **Survey Data Workbench by LAI ZEYU** (Store ID `9NWXQZP2ZG2H`).
- [x] Hard-lock Partner Center Identity `LAIZEYU.SurveyDataWorkbenchbyLAIZEYU`, technical Publisher `CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8`, and Publisher display name `LAI ZEYU` in the production package gate.
- [ ] Choose the final package version and create the Store-associated package.
- [ ] Live Partner Center input: enter the stable privacy-policy URL `https://github.com/lzy2767865503-pixel/spss-auto-workflow/blob/main/store/PRIVACY_POLICY.md`.
- [ ] Live Partner Center input: set Category to the recommended **Productivity** category.
- [ ] Live Partner Center input: set the support URL to `https://github.com/lzy2767865503-pixel/spss-auto-workflow/issues`.
- [ ] Supply final 44/150/310 tile art, Store logo, and accessibility-reviewed listing artwork. Generated development assets are not final marketing art.
- [ ] From the exact hash-verified Windows candidate, capture and manually review at least four 1366×768-or-larger PNG screenshots; do not substitute macOS Playwright/concept renders and do not upload screenshots containing datasets, paths, tokens, licence details, or other sensitive content.
- [x] The Windows build fails closed unless it can generate per-candidate notices from exact Python 3.12.10 and locked distributions (including PyInstaller), all installed locked npm packages, exact .NET 8.0.30 runtime packs, WebView2 1.0.4129.50, and a SHA-256 inventory of the final publish assets; generated notices are included with LICENSE and NOTICE.
- [ ] Complete final legal review of the generated per-candidate notices before submission.
- [ ] Complete the remaining live Partner Center inputs: age rating, markets, pricing, and support-contact fields.
- [ ] Declare Microsoft Edge WebView2 Evergreen Runtime and optional IBM SPSS Statistics interoperability in certification notes.
- [ ] Confirm whether the chosen Store ingestion route expects `.msix`, `.msixupload`, or another package container.
- [ ] Submit only after the privacy, dependency, trademark, and licensed-SPSS evidence is attached.

## Release integrity

- [ ] Tag the tested commit and generate SHA-256 hashes for the submitted package and GitHub release assets.
- [ ] Verify no secrets, respondent data, certificates, `.pfx` files, Partner Center tokens, or private logs are present in Git history or release assets.
- [ ] Use only `windows-github-release.yml` for public GitHub binaries. It publishes one EXE installer separate from the Store MSIX after two reviewer-approved private licensed-SPSS assertions bind the immutable tag/fixture/integration and exact built private layout. Their shared HMAC is integrity-only, not independent environment proof. Build, isolated review, no-checkout sign-only, no-checkout no-signing lifecycle verification, no-checkout exact-ID publication, and cleanup use distinct protected organisation runner groups/accounts. A pinned ACL harness atomically removes every previous writer and freezes each exact handoff; no unsigned binary enters Actions artifacts. The signing harness must keep the reusable CKA TOTP seed off command lines, restore provider/key baselines, never launch repository-derived EXE/DLL bytes, and produce a real recursive inventory proving one exact `LAI ZEYU`/`来泽宇` thumbprint plus RFC 3161/TSA EKU for every PE. A separate verifier with no signing credential must run two identical-byte installer lifecycle passes before fresh exact current-main/peeled-tag checks and publication; an ambiguous create is never adopted.
- [ ] Keep the technical Partner Center Publisher CN separate from visible authorship; only `LAI ZEYU（来泽宇）` is the author and `PublisherDisplayName` remains `LAI ZEYU`.
- [ ] Record Partner Center submission ID separately; an uploaded package is not the same as certification or publication.
