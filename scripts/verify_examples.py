"""Run every ```tessariql block of the given Markdown files against a real tessaridb binary.

Per file: one fresh disk store, namespace `skill` and database `skill` selected before every block.
A block holding a `-- refused:` line must be refused (non-zero exit); every other block must succeed.
`-- with --param name=value` lines bind parameters. A block preceded by `<!-- not run: reason -->`
is skipped and counted. Once a block declares an owner with a password, later blocks sign in as it.

usage: verify_examples.py <tessaridb binary> <file.md>...
"""

import os
import re
import subprocess
import sys
import tempfile

BLOCK = re.compile(r"(<!-- not run: (?P<why>[^>]*) -->\s*\n)?```tessariql\n(?P<body>.*?)```", re.S)
OWNER = re.compile(r"DEFINE USER (\w+) ROLE owner PASSWORD '([^']+)'")
PRE = "USE NAMESPACE skill;\nUSE DATABASE skill;\n"


def run(binary, store, script, params, owner):
    with tempfile.NamedTemporaryFile("w", suffix=".tessariql", delete=False) as f:
        f.write(script)
    cmd = [binary, store, "-f", f.name]
    for p in params:
        cmd += ["--param", p]
    env = dict(os.environ)
    if owner:
        cmd += ["--user", owner[0]]
        env["TESSARIDB_PASSWORD"] = owner[1]
    out = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=120)
    os.unlink(f.name)
    return out.returncode, (out.stdout + out.stderr).strip()


def main():
    binary, files = sys.argv[1], sys.argv[2:]
    total = failed = skipped = 0
    for path in files:
        text = open(path).read()
        store = tempfile.mkdtemp(prefix="skillstore-")
        code, out = run(binary, store, "DEFINE NAMESPACE skill;\nUSE NAMESPACE skill;\nDEFINE DATABASE skill;\n", [], None)
        if code:
            print(f"SETUP FAIL {path}: {out}")
            failed += 1
            continue
        owner = None
        for n, m in enumerate(BLOCK.finditer(text), 1):
            body = m.group("body")
            line = text[: m.start()].count("\n") + 1
            if m.group("why"):
                skipped += 1
                print(f"skip  {path}:{line} ({m.group('why')})")
                continue
            total += 1
            params = re.findall(r"^-- with --param (\S+)", body, re.M)
            refused = re.search(r"^-- refused: (\S+)", body, re.M)
            code, out = run(binary, store, PRE + body, params, owner)
            last = out.splitlines()[-1] if out else ""
            if refused:
                ok = code != 0
                verdict = f"refused as expected ({refused.group(1)}): {last}" if ok else f"NOT REFUSED: {last}"
            else:
                ok = code == 0
                verdict = "ok" if ok else f"FAILED: {last}"
            if not ok:
                failed += 1
            print(f"{'ok   ' if ok else 'FAIL '} {path}:{line} {verdict}")
            found = OWNER.search(body)
            if found and ok:
                owner = (found.group(1), found.group(2))
    print(f"\nblocks run={total} failed={failed} skipped={skipped}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
