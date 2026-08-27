# External Dependencies and Licensing

## Included components

- Self-contained .NET 8.0.30 WPF desktop shell (SDK 8.0.424)
- React/Vite frontend assets
- Python 3.12.10 sidecar built with exact PyInstaller 6.22.2
- Flask, Waitress, pandas, NumPy, openpyxl, pyreadstat, pypdf, xlrd, and their declared transitive dependencies
- Microsoft WebView2 SDK NuGet package (the SDK is not the runtime)

Every Windows candidate generates `legal/THIRD_PARTY_NOTICES.txt` fail closed
from the exact installed versions in both Python lock files, all installed npm
lock entries, exact .NET runtime-pack and SDK licence sources, WebView2
1.0.4129.50, PyInstaller, and a SHA-256 inventory of final publish assets, and
packages it together with `LICENSE.txt`, `NOTICE.md`, and the notices summary.
Build and installed-package gates reject missing or empty legal files. Final
legal review is still required before release; the repository's MIT licence
alone does not replace third-party notices.

## Runtime dependency

The desktop UI requires Microsoft Edge WebView2 Evergreen Runtime. The release
installer/package strategy and Store dependency declaration must be validated on
clean Windows 10 and Windows 11 machines.

## Optional IBM interoperability

IBM SPSS Statistics is not included. Survey Data Workbench by LAI ZEYU only looks for a user's
separately installed `statisticspython3.bat` and corresponding external-Python
runtime, then uses the vendor-provided `spss.StartSPSS()`, `spss.Submit()`, and
`spss.StopSPSS()` integration surface.

Detection of an installation does not prove a valid licence. The UI reports
licensing and integration as unverified. A real execution is labelled only as
format-complete after SAV parses through pyreadstat, SPV passes full ZIP reads,
and PDF passes pypdf structure parsing. Statistical semantics remain unverified
until two authorised IBM SPSS environments complete the external gate. No Store listing or release note
may claim IBM certification, partnership, or bundled rights.
