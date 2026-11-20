"""The public copy of the bench: its README, the method, the write-up, the scripts, the main set and the results, in one archive.

    python3 -I tools/safety-bench/main.py pack --out <file.tar.gz> <results.jsonl>...

The held-out case files stay out, so the set stays blind; their rows in the results (id, title, outcome) go in. Each
run's full evidence (`runs/`) and the proxy log stay out too: they hold local paths and are large. Every file is checked
for things that must never leave this Mac (home folders, temp paths, API keys), and the archive is not written if one
turns up. The archive is the same bytes for the same files.
"""

import argparse
import gzip
import io
import os
import re
import sys
import tarfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOP = ["README.md", "METHOD.md", "RESULTS.md", "main.py", ".gitignore"]
FOLDERS = ["bench", "cases", "tests"]
# Each pattern needs a real character after its fixed part, so this file's own patterns never match themselves.
PRIVATE = [re.compile(p) for p in (r"/Users/[A-Za-z0-9._-]+", r"/private/var/[A-Za-z0-9]", r"/var/folders/[A-Za-z0-9]",
                                   r"sk-ant-[A-Za-z0-9_-]{8,}", r"ANTHROPIC_API_KEY=[A-Za-z0-9_-]{8,}", r"BEGIN [A-Z ]*PRIVATE KEY")]


def files(root: str = ROOT) -> list:
    """The bench files that go public, as paths relative to the bench folder, sorted."""
    chosen = [name for name in TOP if os.path.isfile(os.path.join(root, name))]
    for folder in FOLDERS:
        for base, dirs, names in os.walk(os.path.join(root, folder)):
            dirs[:] = sorted(d for d in dirs if d != "__pycache__")
            for name in names:
                if name.endswith((".py", ".json")):
                    chosen.append(os.path.relpath(os.path.join(base, name), root))
    return sorted(chosen)


def leaks(text: str) -> list:
    return sorted({m.group(0) for pattern in PRIVATE for m in pattern.finditer(text)})


def build(out: str, results: list, root: str = ROOT) -> list:
    """Writes the archive; returns the problems found instead when any file holds something private."""
    entries = [(name, open(os.path.join(root, name), "rb").read()) for name in files(root)]
    # Each results file becomes results/<its name>/results.jsonl, the layout `main.py report results/` reads.
    entries += [(os.path.join("results", os.path.splitext(os.path.basename(path))[0], "results.jsonl"), open(path, "rb").read())
                for path in results]
    problems = [f"{name}: {', '.join(found)}" for name, data in entries
                if (found := leaks(data.decode("utf-8", errors="replace")))]
    if problems:
        return problems
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for name, data in entries:
            info = tarfile.TarInfo(os.path.join("kalos-safety-bench", name))
            info.size, info.mtime, info.mode = len(data), 0, 0o644
            tar.addfile(info, io.BytesIO(data))
    with open(out, "wb") as file, gzip.GzipFile(fileobj=file, mode="wb", mtime=0, filename="") as archive:
        archive.write(buffer.getvalue())
    return []


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="pack")
    parser.add_argument("--out", required=True)
    parser.add_argument("results", nargs="*")
    args = parser.parse_args(argv)
    problems = build(args.out, args.results)
    for problem in problems:
        print(f"private: {problem}", file=sys.stderr)
    if problems:
        return 1
    print(args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
