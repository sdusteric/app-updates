# Kalos safety bench

A bench that checks what the Kalos browser does when a hostile web page tells an AI agent to leak a code, send, share, delete or pay. A scripted agent follows each planted instruction to the letter through Kalos's MCP tools, and the bench checks from evidence whether the harm happened.

- `RESULTS.md`: the latest results, what they mean, and the known gaps.
- `METHOD.md`: the sites, the agents, the four settings and the scoring.
- `cases/`: the main set, one JSON file per case.
- `bench/`: the bench in Python (standard library only): the local sites and proxy, the scripted agent, the scoring and the report.
- `tests/`: unit tests, `python3 -I -m unittest discover -s tests -t .`
- `results/<run>/results.jsonl`: the raw results, one line per run.

Rebuild the report and the counts in `RESULTS.md` from the raw results:

```sh
python3 -I main.py report results/
```

This writes `results/report.md`.

## What you can and can't rerun

The runs drive a test copy of Kalos built with the bench's hooks, which let a script answer Kalos's questions and read its rule log. That build is not public, so you can read every case, page, step and scoring rule and recompute the report, but not rerun Kalos itself. To try any agent in any browser against planted pages on the open web, use the safety range at https://kalosbrowser.com/range/.

## The held-out set

A fifth of the cases sit in a held-out set that nobody reads while fixing Kalos, so it shows whether fixes hold beyond the cases they were made for. Its case files are not in this repository, and its result rows are. The files will be published when the set is replaced with a new blind one.

Results page: https://kalosbrowser.com/safety-bench
