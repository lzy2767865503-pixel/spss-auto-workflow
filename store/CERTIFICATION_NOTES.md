# Draft Certification Notes

Requires a separately installed and licensed IBM SPSS Statistics for optional
formal SPSS execution. Preview-only operation does not require IBM SPSS.

Survey Data Workbench by LAI ZEYU is a packaged x64 desktop application. It starts a private
Python service bound only to a random `127.0.0.1` port. The service requires a
cryptographically random per-launch token for every API and validates Host,
Origin, and Fetch Metadata where supplied. It does not listen on a LAN address.

The manifest declares the restricted `runFullTrust` capability only so the WPF
desktop process can start and stop its bundled local Python sidecar and, when
the user explicitly opts in, call the user's separately installed IBM SPSS
Statistics integration launcher. The application requests no elevation and
runs as the signed-in user. The desktop assigns the sidecar to a Windows Job
Object with `KILL_ON_JOB_CLOSE`; the sidecar also monitors the desktop PID and
closes its loopback server if the parent exits. Developer / 开发者: LAI ZEYU（来泽宇）.

Uploaded files and generated outputs are written to the package's local
application-data area, not the read-only installation directory. Settings allow
retention changes and deletion of all uploaded datasets, job configurations,
previews, and generated outputs. The control is deliberately labelled task-data
deletion; retention preferences, rotating technical logs, and WebView2 support
data are separate and are disclosed in the privacy policy.

The application works in preview-only mode without IBM SPSS Statistics. IBM
SPSS Statistics interoperability is optional; the dependency is proprietary,
is not included in the package, and must be separately installed and licensed
by the user. The product makes no IBM affiliation or certification claim.

For certification without IBM SPSS installed:

1. Launch Survey Data Workbench by LAI ZEYU.
2. Confirm the header reads `IBM SPSS 未检测` and the formal-execution toggle is disabled.
3. Upload `examples/synthetic_survey.csv` (copy it outside the package first if needed).
4. Keep preview mode selected, configure detected constructs, and run.
5. Confirm the ZIP passes a complete integrity read and no SAV, SPV, or PDF is
   present or described as formal output. Format integrity and two-environment
   IBM SPSS statistical-semantic validation are separate release gates.
6. Open Settings to change retention and delete all task data; confirm the UI
   accurately explains which preferences and support data remain.

Privacy policy:
https://github.com/lzy2767865503-pixel/spss-auto-workflow/blob/main/store/PRIVACY_POLICY.md

Support:
https://github.com/lzy2767865503-pixel/spss-auto-workflow/issues

Reserved Partner Center identity: `LAIZEYU.SurveyDataWorkbenchbyLAIZEYU`;
technical Publisher: `CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8`;
Publisher display name: `LAI ZEYU`. These notes are submission input, not
evidence that certification has passed.
