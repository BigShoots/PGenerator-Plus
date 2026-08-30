# Web UI fragments

The `webui.html`, `webui-*.html`, `webui-*.css`, and `webui-*.js` files in this directory are
the byte-sensitive inputs to the server-side Web UI assembler in `webui.pm`.
They are deliberately stored as separate files so front-end changes have
normal editor and diff boundaries while the server continues to emit one
HTML response.

Do not run Prettier, ESLint `--fix`, a formatter-on-save rule, or a tabs-to-
spaces conversion over these files. Their bytes are covered by
`t/webui_html_golden.t`; changing whitespace, line endings, or placeholder
lines changes the rendered response. `icc_profile.html` is spliced into the
same hashed page, so it is exactly as byte-sensitive as the ten fragments;
`icc_profile.css`, `icc_profile.js`, and `hcfr_chc.js` are served verbatim
from `/assets/` and must not be reformatted either.

`webui-colour-math.js` opens with `'use strict';` and is concatenated into
the SAME inline `<script>` block as `webui-app.js` and `webui-workspace.js`,
so the directive governs all three fragments. Any new code in those files
must be strict-mode clean: no undeclared assignments, no `with`, no
block-scoped function declarations relied on across blocks.

The checked-in `t/slice_webui.pl` script was the one-shot extraction
mechanism for the initial split. It asserts against the pre-split heredoc
layout, so it can only run against a tree from before the refactor; on the
current tree it dies by design. The golden hash below is the standing
guarantee.

After an intentional front-end change, refresh the golden hash and commit it
together with the fragment change:

```bash
prove -v t/webui_html_golden.t
```

The failing comparison prints `got: '<new hash>'` next to the expected value.
Confirm the diff you are landing is the only change, then write the new hash
into `t/webui_html_golden.sha256` (single line, no trailing spaces) and re-run
the test to see it pass.

The loader reads every fragment with Perl's `<:raw>` layer. Keep UTF-8 source
bytes and LF endings intact, and do not add banner comments inside fragments.
Migration notes and explanations belong here instead.

Before publishing an OTA archive, verify that the cumulative overlay contains
all ten exact fragment paths with content, plus the four page assets the
served UI also reads from disk (`icc_profile.html`, `icc_profile.css`,
`icc_profile.js`, `hcfr_chc.js`):

```bash
perl t/check_webui_package.pl <release>.tar.gz
```
