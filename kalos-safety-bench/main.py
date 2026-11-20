"""Entry point for `python3 -I`, which leaves the script's folder off the import path: `main.py run ...`, `main.py report ...`
`main.py tasks ...`, `main.py tasks-table <tasks.jsonl>...`, `main.py tokens ...` or
`main.py tokens-compare <before.json> <after.json>` or `main.py pack --out <file.tar.gz> <results.jsonl>...`."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

if __name__ == "__main__":
    command, rest = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else ("run", [])
    if command == "report":
        from bench.report import main
    elif command == "tasks":
        from bench.tasks import main
    elif command == "tasks-table":
        from bench.tasks import table_main as main
    elif command == "tokens":
        from bench.tokens import main
    elif command == "tokens-compare":
        from bench.tokens import compare_main as main
    elif command == "pack":
        from bench.pack import main
    else:
        from bench.run import main
    sys.exit(main(rest))
