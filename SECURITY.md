# Security and Data Privacy

## Research Data

This application is designed for local use. Uploaded datasets and generated
outputs are stored in private application data outside the read-only install
directory. The packaged API binds to a random `127.0.0.1` port and requires a
per-launch token in addition to Host, Origin, and Fetch Metadata checks.

Before sharing a repository copy, confirm that it does not contain:

- respondent-level or personally identifiable information;
- confidential research data;
- API keys, passwords, tokens, or licence information;
- generated SPSS output that should remain private;
- licensed-SPSS private assertion JSON/HMAC material or its private evidence bundle.

Use **Settings > Delete all task data** to remove application-managed uploaded
datasets, job configurations, previews, and outputs. The retention preference,
rotating local service logs, and WebView2 runtime data are separate support
data; use Windows application reset/uninstall when those must also be removed,
and review them before sharing a diagnostic bundle.

## Reporting a Vulnerability

Use the repository's **Security > Report a vulnerability** form so the report
remains private until a fix is available:

https://github.com/lzy2767865503-pixel/spss-auto-workflow/security/advisories/new

Do not open a public issue for an unpatched vulnerability. Never attach private
datasets, respondent records, SPSS licence information, or credentials. A
minimal reproduction should use the committed synthetic fixture whenever
possible.

The trusted Windows release consumes licensed-SPSS private assertions only through the
reviewer-protected `trusted-windows-release-spss-review` GitHub Environment. The shared
HMAC is integrity-only and is not an independent identity or environment proof.
Never place the assertion HMAC key, raw records, screenshots, statistical comparison tables,
or eSigner credentials in repository files, Actions artifacts, release assets,
issues, pull requests, or job summaries.
