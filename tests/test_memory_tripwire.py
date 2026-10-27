"""The measurement-version tripwire.

The memory reuses a measurement only while ``iqa.MEASUREMENT_VERSION`` (part of the analyzer key)
is unchanged, so a change to the measurement code that changes any output must bump it, or every
remembered photo keeps numbers from the old method. This test hashes the syntax tree of each
measurement module, docstrings removed (method notes can change freely), and compares it with a
pinned hash. Formatting and comments are not in the tree either.

When it fails:
* the change alters any output (a number, a flag, a field): bump ``iqa.MEASUREMENT_VERSION`` in
  iqa/__init__.py and pin the new hash with the new version below;
* it does not (a refactor, a rename): confirm the outputs are bit-identical on the golden files
  (the test suite and a results.json from before and after), then re-pin the hash alone.
"""
import ast
import hashlib
import os
import sys

import iqa

# The modules whose code decides a stored measurement. fingerprint is here because dhash256 is
# stored with every measurement.
MEASUREMENT_MODULES = ("imageio", "sfr", "edges", "noise", "exposure", "structure", "uncertainty", "analyze",
                       "fingerprint")

PINNED = {"version": 1, "ast_sha256": "6ee5cebf14521e14923160cf4b14dc47284211bd7fab7069ae70209d5c2a416e"}

IQA_DIR = os.path.dirname(os.path.abspath(iqa.__file__))


def _strip_docstrings(tree: ast.AST) -> ast.AST:
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            body = node.body
            if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant) \
                    and isinstance(body[0].value.value, str):
                node.body = body[1:] or [ast.Pass()]
    return tree


def _dump(source: str) -> str:
    # show_empty (Python 3.13+) keeps the 3.12 form, so the hash does not depend on the interpreter.
    kw = {"show_empty": True} if sys.version_info >= (3, 13) else {}
    return ast.dump(_strip_docstrings(ast.parse(source)), annotate_fields=True, include_attributes=False, **kw)


def code_hash(sources: dict) -> str:
    h = hashlib.sha256()
    for name in MEASUREMENT_MODULES:
        h.update(name.encode() + b"\0" + _dump(sources[name]).encode() + b"\0")
    return h.hexdigest()


def _sources() -> dict:
    out = {}
    for name in MEASUREMENT_MODULES:
        with open(os.path.join(IQA_DIR, f"{name}.py"), encoding="utf-8") as fh:
            out[name] = fh.read()
    return out


def test_measurement_code_matches_the_pinned_version():
    got = code_hash(_sources())
    assert iqa.MEASUREMENT_VERSION == PINNED["version"] and got == PINNED["ast_sha256"], (
        f"The measurement code ({', '.join(MEASUREMENT_MODULES)}) changed: its hash is {got}, pinned "
        f"{PINNED['ast_sha256']} for MEASUREMENT_VERSION {PINNED['version']} (now {iqa.MEASUREMENT_VERSION}). "
        "If the change alters any output, bump iqa.MEASUREMENT_VERSION in iqa/__init__.py so remembered photos "
        "are measured again, and pin the new hash with the new version in tests/test_memory_tripwire.py. If it "
        "does not, confirm the outputs are identical before and after, then re-pin the hash alone.")


def test_docstrings_and_comments_do_not_trip_it_but_code_does():
    base = '''"""Module notes."""
import math


class Edge:
    """A class note."""

    def mtf50(self, x):
        """Method notes, version 1."""
        return math.sqrt(x) * 0.5
'''
    notes = base.replace("Method notes, version 1.", "Method notes, rewritten at length.").replace(
        '"""Module notes."""', '"""Other module notes."""\n# and a comment')
    code = base.replace("* 0.5", "* 0.51")
    only_doc = base.replace('        """Method notes, version 1."""\n', "")
    assert _dump(base) == _dump(notes) == _dump(only_doc)
    assert _dump(base) != _dump(code)
    sources = {name: base for name in MEASUREMENT_MODULES}
    assert code_hash(sources) == code_hash({**sources, "noise": notes})
    assert code_hash(sources) != code_hash({**sources, "noise": code})
