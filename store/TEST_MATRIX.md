# Windows Release Test Matrix

| Gate | Windows 10 x64 | Windows 11 x64 | Current state |
|---|---|---|---|
| Clean MSIX install and first launch | Required twice | Required twice | Two-pass temporary-sign/install/launch workflow implemented; first CI run pending |
| WebView2 present, exact external title, and loopback sidecar ready | Required | Required | Two-pass external installed-app evidence implemented without a production CI/DOM hook; first Windows run pending |
| WebView2 absent/recovery message | Required | Required | Pending |
| Random loopback port and token rejection | CI + manual | CI + manual | Source and packaged macOS sidecar checks pass; Windows CI pending |
| Upload CSV/XLSX/SAV and reject unsupported file | Required | Required | Python API tests partly cover |
| Preview-only fixture upload/poll/ZIP/delete | Required twice | Required twice | Frozen sidecar and installed MSIX checks implemented in each pass; Windows pending |
| Licensed IBM SPSS format integrity | Authorised environment | Authorised environment | Full SAV/SPV/PDF parsers implemented; authorised run pending |
| Licensed IBM SPSS semantic result comparison | Authorised environment | Different authorised environment | Not verified; reviewer-approved private assertions bind tag/fixture/integration and the exact built private layout plus delta/tolerance results. Shared HMAC is integrity-only and does not prove independent environment identity/facts |
| IBM missing/unlicensed/partial-output failures | Required | Required | Unit contracts present; hardware pending |
| Settings persistence and expiry cleanup | Required | Required | Local API tests cover retention; installed-package persistence remains pending |
| Delete one job / delete all task data with accurate retained-support-data disclosure | Required | Required | Local API and browser checks pass; Windows pending |
| Same immutable candidate in QA pass 1 and 2 | Required | Required | Protected exact-current-main builder creates one private ACL candidate; each OS runner signs once and verifies identical candidate/MSIX hashes across two sequential passes; Windows run pending |
| Exact `LAI ZEYU（来泽宇）` attribution | Required | Required | Source metadata gate passes locally; each Windows pass also inspects compiled EXE metadata; Windows run pending |
| Upgrade preserves expected data | Required | Required | Pending |
| Force-close WPF terminates sidecar and WebView2 children | Required twice | Required twice | Job Object + independent parent watchdog and two-pass CI check implemented; first Windows run pending |
| Uninstall and reinstall | Required | Required | Two-pass uninstall/LocalState-removal/relaunch workflow implemented; update/repair and first Windows run pending |
| Keyboard-only, screen reader, high contrast, 200% scale | Required | Required | Pending |
| Windows App Certification Kit | Required | Required | Strict two-pass protected-approved appcert hash/file-version + `reset` + package-path test + fresh XML `PASS`/non-partial/report-hash gate implemented; first Windows report pending |
| Public Actions evidence boundary | Required | Required | Unsigned candidates remain on private ACL share; only fixed-schema JSON + SHA-256 may upload after success, with build/review provenance and private input hashes, never raw reports/binaries/packages/certificates/keys |
| GitHub EXE installer signer/lifecycle | Exact trusted author signer | Exact trusted author signer | Separate build/review/sign-only/no-signing-verifier/publisher/cleanup organisation runner groups and atomic owner/ACL handoffs implemented; release remains blocked until the external ACL/signing/verification harnesses, certificate, and private assertions exist, recursive inventory proves one exact signer/RFC-3161/TSA EKU for every PE, and the independent verifier runs identical installer bytes twice |

Do not mark a Store release ready from macOS/Linux tests or development-MSIX
creation alone.
