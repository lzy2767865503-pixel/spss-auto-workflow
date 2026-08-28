# Third-Party Notices Summary

Survey Data Workbench by LAI ZEYU is developed by **LAI ZEYU（来泽宇）** and
distributed under the repository's MIT licence. Its Windows package contains
third-party components under compatible open-source licences.

The locked runtime includes Python, Flask/Waitress, pandas, NumPy, openpyxl,
pyreadstat, pypdf, xlrd and their locked transitive dependencies; React, React DOM,
Lucide React and Scheduler; the self-contained Microsoft .NET 8 runtime; the
Microsoft Edge WebView2 SDK assemblies; and the PyInstaller bootloader under its
distribution exception. IBM SPSS Statistics and its licence are not included.

Every Windows candidate runs `scripts/Generate-ThirdPartyNotices.py` against
exact Python 3.12.10 and both lock files (including PyInstaller), every installed
npm lock entry, .NET SDK 8.0.424 and exact 8.0.30 runtime packs, WebView2
1.0.4129.50, and the final publish asset inventory.
The generated `legal/THIRD_PARTY_NOTICES.txt` contains the exact versions,
declared licence metadata, upstream locations and all licence/NOTICE files
exposed by those installed distributions plus SHA-256s for the final assets and
license sources. The build rejects version drift or missing sources; CI rejects a candidate if this file,
the repository `LICENSE`, or `NOTICE.md` is absent or empty.

This summary is not a substitute for the generated per-candidate notice file.
