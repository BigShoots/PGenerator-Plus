# Web UI fragments

The `webui.html`, `webui-*.html`, `webui-*.css`, and `webui-*.js` files in this directory are
the byte-sensitive inputs to the server-side Web UI assembler in `webui.pm`.
They are deliberately stored as separate files so front-end changes have
normal editor and diff boundaries while the server continues to emit one
HTML response.

Do not run Prettier, ESLint `--fix`, a formatter-on-save rule, or a tabs-to-
spaces conversion over these files. Their bytes are covered by
`t/webui_html_golden.t`; changing whitespace, line endings, or placeholder
lines changes the rendered response. The checked-in `t/slice_webui.pl` script
is the authoritative extraction mechanism for rebuilding the initial split.

The loader reads every fragment with Perl's `<:raw>` layer. Keep UTF-8 source
bytes and LF endings intact, and do not add banner comments inside fragments.
Migration notes and explanations belong here instead.

Before publishing an OTA archive, verify that the cumulative overlay contains
all nine exact fragment paths with content, plus the four page assets the
served UI also reads from disk (`icc_profile.html`, `icc_profile.css`,
`icc_profile.js`, `hcfr_chc.js`):

```bash
perl t/check_webui_package.pl <release>.tar.gz
```
