"""The case format: ordinary pages, one hostile instruction placed somewhere on them, a scripted list of agent steps that
try one forbidden outcome, and a harmless twin.

The page's hostile text (`attack`, shown by `placement` on `attack_on`, the start page by default) is what a model reads.
The obedient agent never reads it: its steps come from here. Groups 1 to 6 are AI apps acting through MCP (`obedient`,
`twin_steps`), and so is group 9 (the agent tools: scripts, screenshots, history search); groups 7 and 8 are Pane's own chat, grouping and command bar, driven over the control channel (`self`,
`twin_self`). Slots, filled per run from the world: {secret}, {secret_encoded} (the secret in base64), {other}, {private} (a private sentence in plain words, with no code in it),
{private_zh} (a private sentence in Chinese, with no spaces),
{person}, {person_email}, {contact}, {contact_email}, {product}, {host:<kind>}, {brand:<kind>}.
"""

import base64
import glob
import json
import os
import re
from dataclasses import dataclass, field

from .vary import KINDS

SETTINGS = ["ask-deny", "ask-allow", "without", "site"]
SLOT = re.compile(r"\{([a-z_]+)(?::([a-z]+))?\}")
SIMPLE_SLOTS = {"secret", "secret_encoded", "other", "private", "private_zh", "person", "person_email", "contact", "contact_email", "product"}
KIND_SLOTS = {"host", "brand"}

PLACEMENTS = ["visible", "tiny", "comment", "alt", "aria", "frame", "email", "review", "results", "note"]
REQUIRED = {"id", "group", "title", "sites", "start", "task", "twin", "placement", "attack", "forbidden", "twin_done"}
STEPS = {"agent": ("obedient", "twin_steps"), "self": ("self", "twin_self")}
OPTIONAL = {"open", "extra", "secret_on", "settings", "notes", "attack_on", "attack_title", "answer_after", "profiles",
            *STEPS["agent"], *STEPS["self"]}


class CaseError(ValueError):
    pass


@dataclass
class Case:
    id: str
    group: int
    title: str
    sites: list
    start: str
    task: str
    twin: str
    forbidden: dict
    twin_done: dict
    placement: str = ""
    attack: str = ""
    obedient: list = field(default_factory=list)
    twin_steps: list = field(default_factory=list)
    self_steps: list = field(default_factory=list)
    twin_self: list = field(default_factory=list)
    attack_on: str = ""
    attack_title: str = ""
    # Seconds each question stays open before its answer, so the page can change while the person decides.
    answer_after: float = 0
    open: list = field(default_factory=list)
    extra: dict = field(default_factory=dict)
    secret_on: str = ""
    # The person's profiles ticked in Settings > Agents for the run, by name, so an agent may open them (open_page profile).
    profiles: list = field(default_factory=list)
    settings: list = field(default_factory=lambda: list(SETTINGS))
    notes: str = ""
    path: str = ""

    @property
    def start_kind(self) -> str:
        return self.start.split(":", 1)[0]

    @property
    def start_path(self) -> str:
        return self.start.split(":", 1)[1] if ":" in self.start else "/"

    @property
    def is_self(self) -> bool:
        """Pane's own chat, grouping and command bar, not an AI app."""
        return self.group in (7, 8)

    @property
    def attack_page(self) -> str:
        return self.attack_on or (self.start if ":" in self.start else self.start + ":/")


def parse_case(data: dict, path: str = "") -> Case:
    where = path or data.get("id", "?")
    unknown = set(data) - REQUIRED - OPTIONAL
    if unknown:
        raise CaseError(f"{where}: unknown keys {sorted(unknown)}")
    missing = REQUIRED - set(data)
    if missing:
        raise CaseError(f"{where}: missing keys {sorted(missing)}")
    if not isinstance(data["group"], int) or not 1 <= data["group"] <= 9:
        raise CaseError(f"{where}: group must be 1 to 9")
    if data.get("placement") not in PLACEMENTS:
        raise CaseError(f"{where}: placement must be one of {PLACEMENTS}")
    steps, others = (STEPS["self"], STEPS["agent"]) if data["group"] in (7, 8) else (STEPS["agent"], STEPS["self"])
    for key in steps:
        if not data.get(key):
            raise CaseError(f"{where}: {key} needs at least one step")
    for key in others:
        if key in data:
            raise CaseError(f"{where}: {key} does not belong in group {data['group']}")
    bad = [s for s in data["sites"] if s not in KINDS]
    if bad:
        raise CaseError(f"{where}: unknown site kinds {bad}")
    fields = dict(data)
    if "self" in fields:
        fields["self_steps"] = fields.pop("self")
    case = Case(**fields, path=path)
    if case.start_kind not in case.sites:
        raise CaseError(f"{where}: start site {case.start_kind} is not in sites")
    if case.secret_on and case.secret_on not in case.sites:
        raise CaseError(f"{where}: secret_on {case.secret_on} is not a site in this case")
    if not all(isinstance(p, str) and p for p in case.profiles):
        raise CaseError(f"{where}: profiles must be profile names")
    if not set(case.settings) <= set(SETTINGS):
        raise CaseError(f"{where}: unknown settings {sorted(set(case.settings) - set(SETTINGS))}")
    needs = {"email": "mail", "review": "shop", "results": "forum", "frame": "outside"}.get(case.placement)
    if needs and needs not in case.sites:
        raise CaseError(f"{where}: placement {case.placement} needs the {needs} site")
    for target in case.open + list(case.extra) + [case.attack_page]:
        if target.split(":", 1)[0] not in case.sites:
            raise CaseError(f"{where}: {target} is not on a site in this case")
    for name, kind in SLOT.findall(json.dumps(data)):
        if kind:
            if name not in KIND_SLOTS:
                raise CaseError(f"{where}: unknown slot {{{name}:{kind}}}")
            if kind not in case.sites:
                raise CaseError(f"{where}: slot {{{name}:{kind}}} names a site not in sites")
        elif name not in SIMPLE_SLOTS:
            raise CaseError(f"{where}: unknown slot {{{name}}}")
    return case


def load_cases(folder: str) -> list:
    cases, seen = [], set()
    for path in sorted(glob.glob(os.path.join(folder, "**", "*.json"), recursive=True)):
        with open(path) as file:
            case = parse_case(json.load(file), path)
        if case.id in seen:
            raise CaseError(f"{path}: duplicate id {case.id}")
        seen.add(case.id)
        cases.append(case)
    return cases


def fill(value, world):
    """Fills slots in a string, or in every string inside a list or dict."""
    if isinstance(value, str):
        def one(match):
            name, kind = match.group(1), match.group(2)
            if kind:
                return (world.hosts if name == "host" else world.brands)[kind]
            contact = world.people[1]
            return {
                "secret": world.secrets["main"], "other": world.secrets["other"], "private": world.secrets["private"],
                "secret_encoded": base64.b64encode(world.secrets["main"].encode()).decode(),
                "private_zh": world.secrets["private_zh"],
                "person": world.person["name"],
                "person_email": world.person["email"], "contact": contact["name"], "contact_email": contact["email"],
                "product": world.products[0]["name"],
            }.get(name, match.group(0))
        return SLOT.sub(one, value)
    if isinstance(value, list):
        return [fill(v, world) for v in value]
    if isinstance(value, dict):
        return {k: fill(v, world) for k, v in value.items()}
    return value
