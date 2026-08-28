#!/usr/bin/env python3
"""Refuse syntax the appliance's interpreters cannot parse.

The Pi 4 appliance runs CPython 3.5, and usr/bin/pgen_colour_math.py is
additionally imported from a bare ``python`` heredoc in meter_series.sh, which
may be a Python 2. Nothing on a workstation or in CI runs either interpreter,
so a modern construct compiles clean everywhere it is tested and fails only on
the device, at the moment an operator is mid-calibration.

This is a syntax screen, not a full parse under the older interpreters: it
walks each file's AST and rejects the constructs that would not parse there.
It cannot see a library or method that arrived after 3.5 -- that still needs
review -- but it closes the whole class of "a newer syntax slipped in".
"""

from __future__ import print_function

import ast
import os
import sys


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "usr", "bin")

# node name -> the version that introduced it, and what to write instead.
AFTER_35 = {
    "JoinedStr": ("3.6 f-string", 'use "{}".format(...)'),
    "FormattedValue": ("3.6 f-string", 'use "{}".format(...)'),
    "AnnAssign": ("3.6 variable annotation", "use a plain assignment"),
    "NamedExpr": ("3.8 walrus operator", "assign on its own line"),
    "Match": ("3.10 match statement", "use if/elif"),
    "MatchValue": ("3.10 match statement", "use if/elif"),
    "TryStar": ("3.11 except*", "use except"),
}

# Additionally rejected in the one module a Python 2 heredoc imports.
PY2_HOSTILE = {
    "Nonlocal": ("3.0 nonlocal", "rebind through a mutable holder"),
    "YieldFrom": ("3.3 yield from", "loop and yield"),
    "Starred": ("3.0 starred assignment target", "index explicitly"),
}
PY2_ALSO_IMPORTED_BY_PYTHON2 = "pgen_colour_math.py"

problems = []
checked = 0


def report(path, node, why):
    problems.append("{}:{}: {} ({})".format(
        os.path.relpath(path, ROOT), getattr(node, "lineno", "?"), why[0], why[1]))


for name in sorted(os.listdir(BIN)):
    if not name.endswith(".py"):
        continue
    path = os.path.join(BIN, name)
    with open(path) as handle:
        source = handle.read()
    tree = ast.parse(source, filename=path)
    checked += 1
    py2 = name == PY2_ALSO_IMPORTED_BY_PYTHON2
    for node in ast.walk(tree):
        kind = type(node).__name__
        if kind in AFTER_35:
            report(path, node, AFTER_35[kind])
        if py2 and kind in PY2_HOSTILE:
            # A Starred node is only a problem as an assignment target; in a
            # call or a literal it is PEP 448, which Python 2 also rejects,
            # so both readings are refused here anyway.
            report(path, node, PY2_HOSTILE[kind])
        if py2 and kind == "FunctionDef":
            if node.args.kwonlyargs:
                report(path, node, ("3.0 keyword-only argument",
                                    "take it positionally or from a dict"))
            if any(argument.annotation for argument in node.args.args):
                report(path, node, ("3.0 argument annotation",
                                    "describe the type in the docstring"))
            if node.returns is not None:
                report(path, node, ("3.0 return annotation",
                                    "describe the type in the docstring"))
        if kind == "FunctionDef" and getattr(node.args, "posonlyargs", None):
            report(path, node, ("3.8 positional-only argument",
                                "use ordinary parameters"))

if problems:
    for problem in sorted(problems):
        print(problem, file=sys.stderr)
    raise SystemExit(1)

print("{} on-device Python files parse within the appliance's syntax".format(checked))
