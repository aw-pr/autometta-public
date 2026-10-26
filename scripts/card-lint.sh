#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
strict=false

if [[ "${1:-}" == "--strict" ]]; then
  strict=true
  shift
fi

if [[ $# -eq 0 ]]; then
  printf 'usage: %s [--strict] <card>...\n' "${0##*/}" >&2
  exit 2
fi

python3 -I - "$strict" "$script_dir/check-contract-test-gate.sh" "$@" <<'PY'
import os
import re
import subprocess
import sys


strict = sys.argv[1] == "true"
gate = sys.argv[2]
card_arguments = sys.argv[3:]
started_from = os.path.realpath(os.getcwd())

for argument in card_arguments:
    if not os.path.isfile(argument):
        print(f"card-lint: no such card: {argument}", file=sys.stderr)
        sys.exit(2)


def repository_root(card_path):
    directory = os.path.dirname(os.path.realpath(card_path))
    result = subprocess.run(
        ["git", "-C", directory, "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        return os.path.realpath(result.stdout.strip())
    return started_from


def sections_from(lines):
    sections = {}
    current = None
    for line in lines:
        if line.startswith("## "):
            current = line[3:].strip()
            sections.setdefault(current, [])
        elif current is not None:
            sections[current].append(line)
    return sections


def section_with_prefix(sections, prefix):
    for heading, body in sections.items():
        if heading.startswith(prefix):
            return body
    return None


def outside_fences(lines):
    result = []
    fenced = False
    for line in lines:
        if line.startswith("```"):
            fenced = not fenced
            continue
        if not fenced:
            result.append(line)
    return result


def inline_code_spans(text):
    spans = []
    position = 0
    while position < len(text):
        opener = re.search(r"`+", text[position:])
        if opener is None:
            break
        start = position + opener.start()
        delimiter = opener.group(0)
        cursor = position + opener.end()
        while cursor < len(text):
            closer = re.search(r"`+", text[cursor:])
            if closer is None:
                cursor = len(text)
                break
            close_start = cursor + closer.start()
            close_end = cursor + closer.end()
            if len(closer.group(0)) == len(delimiter):
                spans.append((start, close_end, delimiter, text[start + len(delimiter):close_start]))
                position = close_end
                break
            cursor = close_end
        if cursor >= len(text) and (not spans or spans[-1][0] != start):
            break
    return spans


def without_inline_code(text):
    result = []
    position = 0
    for start, end, _delimiter, _content in inline_code_spans(text):
        result.append(text[position:start])
        position = end
    result.append(text[position:])
    return "".join(result)


def metadata_value(lines, name):
    pattern = re.compile(rf"^- \*\*{re.escape(name)}:\*\*\s*(.*)$")
    for index, line in enumerate(lines):
        match = pattern.match(line)
        if match is None:
            continue
        value = match.group(1).strip()
        for continuation in lines[index + 1:]:
            if not continuation[:1].isspace():
                break
            value = f"{value} {continuation.strip()}".strip()
        return value
    return None


def path_token(value):
    value = re.sub(r":\d+(?:-\d+)?$", "", value)
    if "/" not in value or value.startswith(("/", "~")):
        return None
    if any(character in value for character in (" ", "*", "<", ">", "$", "(")):
        return None
    if not (value.endswith("/") or re.search(r"\.[A-Za-z0-9][A-Za-z0-9._-]*$", value)):
        return None
    return value


def path_tokens(lines):
    for _start, _end, delimiter, value in inline_code_spans("\n".join(outside_fences(lines))):
        if len(delimiter) != 1:
            continue
        token = path_token(value)
        if token is not None:
            yield token


def family(identity):
    if identity is None:
        return None
    lowered = identity.lower()
    if "claude" in lowered:
        return "claude"
    if "codex" in lowered or "gpt" in lowered:
        return "codex"
    if "gemini" in lowered:
        return "gemini"
    return None


def contract_test_finding(lines, root, card_relative):
    test_file = metadata_value(lines, "Test file")
    if test_file is None:
        return None
    test_file = test_file.strip().strip("`")
    if test_file.lower() == "none":
        return None
    test_path = os.path.join(root, test_file)
    if not os.path.isfile(test_path):
        return f"add the named contract test '{test_file}' or change Test file to its existing path"

    with open(test_path, encoding="utf-8") as handle:
        test_text = handle.read()
    if "AUTOMETTA-CONTRACT-NONE" in test_text:
        return f"remove AUTOMETTA-CONTRACT-NONE from '{test_file}' or set Test file to None"

    marker = re.search(r"AUTOMETTA-CONTRACT-BEGIN(?:[^\n]*?)\bcard=([^\s]+)", test_text)
    if marker is None:
        return f"add an AUTOMETTA-CONTRACT-BEGIN marker naming card={card_relative} to '{test_file}'"
    if marker.group(1) != card_relative:
        return f"change '{test_file}' BEGIN marker to card={card_relative}"

    declared = metadata_value(lines, "Assertions digest")
    digest_match = re.search(r"sha256:[0-9a-f]{64}", declared or "")
    if digest_match is None:
        return f"record the digest from scripts/check-contract-test-gate.sh print {test_file}"
    result = subprocess.run([gate, "print", test_path], capture_output=True, text=True)
    recomputed = result.stdout.strip() if result.returncode == 0 else ""
    if recomputed != digest_match.group(0):
        return f"replace Assertions digest with the output of scripts/check-contract-test-gate.sh print {test_file}"
    return None


def read_card(argument):
    try:
        with open(argument, encoding="utf-8") as handle:
            return handle.read().splitlines()
    except (OSError, UnicodeDecodeError):
        print(f"card-lint: cannot read card: {argument}", file=sys.stderr)
        sys.exit(2)


notes = {}


def lint_card(argument):
    card_path = os.path.realpath(argument)
    root = repository_root(card_path)
    card_relative = os.path.relpath(card_path, root)
    lines = read_card(card_path)

    sections = sections_from(lines)
    prose = "\n".join(outside_fences(lines))
    prose_without_code = without_inline_code(prose)
    findings = []

    if re.search(r"<<[^<>]+>>", prose_without_code):
        findings.append(("placeholder", "replace the remaining <<placeholder>> with the card's real value"))

    decisions = metadata_value(lines, "Open decisions")
    if decisions is None:
        findings.append(("open-decisions", "add '- **Open decisions:** none' or list and resolve the open questions"))
    elif not re.fullmatch(r"none\.?", decisions, flags=re.IGNORECASE):
        findings.append(("open-decisions", "resolve the listed questions and change Open decisions to none"))

    worker_family = family(metadata_value(lines, "Worker"))
    verifier_family = family(metadata_value(lines, "Verifier"))
    rationale = metadata_value(lines, "Pairing rationale") or ""
    if (
        worker_family is not None
        and worker_family == verifier_family
        and re.search(r"same(?:-| )family", rationale, flags=re.IGNORECASE) is None
    ):
        findings.append(("pairing", "add 'same-family' to Pairing rationale or choose a verifier from another family"))

    # xhigh and max multiply thinking tokens on every turn of a long run and
    # burned weekly quota on cards nobody had asked to run that hard.
    for role in ("Worker", "Verifier"):
        effort = (metadata_value(lines, f"{role} effort") or "").strip().lower()
        if effort in ("xhigh", "max") and not (metadata_value(lines, "Effort approved") or "").strip():
            findings.append(("effort", f"lower {role} effort to high, or add '- **Effort approved:** <the operator's request>'"))
            break

    # Advisory only: the frontier tier lands high-complexity and UI work in
    # fewer attempts, and costs most when it is in a role that does not need it.
    for role in ("Worker", "Verifier"):
        identity = metadata_value(lines, role) or ""
        if re.search(r"fable|astra", identity, flags=re.IGNORECASE):
            if role == "Worker":
                advice = (f"{identity} is the Worker; confirm the card is high-complexity or UI work "
                          "where the frontier tier lands in fewer attempts, and keep it if so")
            else:
                advice = (f"{identity} is the Verifier; checking criteria is a reading task where a cheaper "
                          "cross-family model usually gets there sooner, unless judging this card needs the frontier tier")
            notes.setdefault(argument, []).append(("frontier-tier", advice))

    if metadata_value(lines, "Worker wall-clock") is None:
        findings.append(("budget", "add a '- **Worker wall-clock:** <duration>' line under Budget"))
    elif metadata_value(lines, "Verifier wall-clock") is None:
        findings.append(("budget", "add a '- **Verifier wall-clock:** <duration>' line under Budget"))

    required_headings = (
        "Metadata",
        "Objective",
        "Deliverables",
        "Acceptance criteria",
        "Contract test",
        "Budget",
    )
    missing_heading = next(
        (required for required in required_headings if section_with_prefix(sections, required) is None),
        None,
    )
    if missing_heading is not None:
        findings.append(("headings", f"add the missing '## {missing_heading}' section"))

    inputs = section_with_prefix(sections, "Inputs")
    if inputs is not None:
        missing_input = next(
            (token for token in path_tokens(inputs) if not os.path.exists(os.path.join(root, token))),
            None,
        )
        if missing_input is not None:
            findings.append(("inputs", f"add the input '{missing_input}' under the repository root or correct its path"))

    claims_value = metadata_value(lines, "Path claims")
    deliverables = section_with_prefix(sections, "Deliverables") or []
    if claims_value is not None:
        claims = [claim.strip().rstrip("/") for claim in claims_value.split(",") if claim.strip()]
        unclaimed = None
        for line in outside_fences(deliverables):
            match = re.match(r"^\s*\d+\.\s+`([^`]+)`", line)
            if match is None:
                continue
            deliverable = path_token(match.group(1))
            if deliverable is None:
                continue
            deliverable = deliverable.rstrip("/")
            if deliverable == card_relative or deliverable == "state" or deliverable.startswith("state/"):
                continue
            if not any(deliverable == claim or deliverable.startswith(claim + "/") for claim in claims):
                unclaimed = deliverable
                break
        if unclaimed is not None:
            findings.append(("claims", f"add '{unclaimed}' to Path claims or remove it from the numbered Deliverables"))

    absolute_line = next(
        (line for line in lines if re.search(r"(?:/Users|/home)/", line)),
        None,
    )
    if absolute_line is not None:
        findings.append(("absolute-path", "replace the absolute home-directory path with a repository-relative path"))

    contract_finding = contract_test_finding(lines, root, card_relative)
    if contract_finding is not None:
        findings.append(("contract-test", contract_finding))

    return findings


any_findings = False
level = "ERROR" if strict else "WARN"
for card_argument in card_arguments:
    card_findings = lint_card(card_argument)
    for check, message in notes.get(card_argument, []):
        print(f"card-lint: NOTE {card_argument}: {check}: {message}")
    if not card_findings:
        print(f"card-lint: OK {card_argument}")
        continue
    any_findings = True
    for check, message in card_findings:
        print(f"card-lint: {level} {card_argument}: {check}: {message}")

sys.exit(1 if strict and any_findings else 0)
PY
