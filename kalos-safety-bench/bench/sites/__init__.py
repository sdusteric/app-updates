"""The sites, one module per kind. `build(world, case)` returns the proxy's host table for one run."""

from importlib import import_module


def build(world, case) -> dict:
    return {world.hosts[kind]: import_module(f".{kind}", __name__).make(world, case) for kind in case.sites}
