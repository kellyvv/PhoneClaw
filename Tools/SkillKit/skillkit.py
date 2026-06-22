#!/usr/bin/env python3
"""Draft generator for PhoneClaw Skill Contract V2 manifests."""

from __future__ import annotations

import json
import pathlib
import sys
from typing import Any


REQUIRED_FIELDS = {
    "id",
    "name",
    "description",
    "type",
    "triggers",
    "allowed_tools",
    "examples",
    "body",
}

LOCALES = {"zh": "SKILL.md", "en": "SKILL.en.md", "ja": "SKILL.ja.md"}


class SkillKitError(Exception):
    pass


def load_manifest(path: pathlib.Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except json.JSONDecodeError as exc:
        raise SkillKitError(f"invalid JSON: {exc}") from exc
    except OSError as exc:
        raise SkillKitError(f"cannot read manifest: {exc}") from exc

    if not isinstance(data, dict):
        raise SkillKitError("manifest root must be a JSON object")
    return data


def require_string(manifest: dict[str, Any], key: str) -> str:
    value = manifest.get(key)
    if not isinstance(value, str) or not value.strip():
        raise SkillKitError(f"`{key}` must be a non-empty string")
    return value.strip()


def require_string_list(manifest: dict[str, Any], key: str) -> list[str]:
    value = manifest.get(key)
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise SkillKitError(f"`{key}` must be a list of strings")
    return [item.strip() for item in value if item.strip()]


def validate_manifest(manifest: dict[str, Any]) -> None:
    missing = sorted(REQUIRED_FIELDS.difference(manifest))
    if missing:
        raise SkillKitError(f"missing required fields: {', '.join(missing)}")

    skill_id = require_string(manifest, "id")
    if "/" in skill_id or "\\" in skill_id or skill_id.startswith("."):
        raise SkillKitError("`id` must be a safe directory name")

    skill_type = require_string(manifest, "type")

    require_string(manifest, "name")
    require_string(manifest, "description")
    require_string_list(manifest, "triggers")
    allowed_tools = require_string_list(manifest, "allowed_tools")
    if skill_type != "content" and not allowed_tools:
        raise SkillKitError("non-content skills should declare at least one allowed tool")

    examples = manifest.get("examples")
    if not isinstance(examples, list):
        raise SkillKitError("`examples` must be a list")
    for index, example in enumerate(examples):
        if not isinstance(example, dict):
            raise SkillKitError(f"`examples[{index}]` must be an object")
        if not isinstance(example.get("query"), str) or not example["query"].strip():
            raise SkillKitError(f"`examples[{index}].query` must be a non-empty string")
        if "scenario" in example and not isinstance(example["scenario"], str):
            raise SkillKitError(f"`examples[{index}].scenario` must be a string when present")

    body = manifest.get("body")
    if not isinstance(body, dict):
        raise SkillKitError("`body` must be an object keyed by locale")
    if not isinstance(body.get("zh"), str) or not body["zh"].strip():
        raise SkillKitError("`body.zh` must be a non-empty string")


def yaml_scalar(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    text = str(value)
    if not text:
        return '""'
    if any(char in text for char in [":", "#", "\n", '"']):
        return json.dumps(text, ensure_ascii=False)
    return text


def render_frontmatter(manifest: dict[str, Any]) -> str:
    lines = [
        "---",
        f"name: {yaml_scalar(manifest['name'])}",
    ]
    if manifest.get("name_zh"):
        lines.append(f"name-zh: {yaml_scalar(manifest['name_zh'])}")
    lines.extend(
        [
            f"description: {yaml_scalar(manifest['description'])}",
            f"version: {yaml_scalar(manifest.get('version', '1.0.0'))}",
            f"icon: {yaml_scalar(manifest.get('icon', 'wrench'))}",
            f"disabled: {yaml_scalar(bool(manifest.get('disabled', False)))}",
            f"type: {yaml_scalar(manifest['type'])}",
            f"requires-time-anchor: {yaml_scalar(bool(manifest.get('requires_time_anchor', False)))}",
            "triggers:",
        ]
    )
    for trigger in manifest["triggers"]:
        lines.append(f"  - {yaml_scalar(trigger)}")
    lines.append("allowed-tools:")
    for tool_name in manifest["allowed_tools"]:
        lines.append(f"  - {yaml_scalar(tool_name)}")
    lines.append("examples:")
    for example in manifest["examples"]:
        lines.append(f"  - query: {yaml_scalar(example['query'])}")
        if example.get("scenario"):
            lines.append(f"    scenario: {yaml_scalar(example['scenario'])}")
    if manifest.get("chip_prompt"):
        lines.append(f"chip_prompt: {yaml_scalar(manifest['chip_prompt'])}")
    if manifest.get("chip_label"):
        lines.append(f"chip_label: {yaml_scalar(manifest['chip_label'])}")
    lines.append("---")
    return "\n".join(lines)


def localized_body(manifest: dict[str, Any], locale: str) -> str:
    body = manifest["body"]
    return str(body.get(locale) or "").strip()


def render_skill_file(manifest: dict[str, Any], locale: str) -> str:
    return render_frontmatter(manifest) + "\n\n" + localized_body(manifest, locale) + "\n"


def render_scenario(manifest: dict[str, Any]) -> str:
    skill_id = manifest["id"]
    first_example = manifest["examples"][0]
    expected_tools = manifest["allowed_tools"]
    tool_list = "[" + ", ".join(expected_tools) + "]"
    description = first_example.get("scenario") or f"Generated SkillKit smoke scenario for {skill_id}."
    return f"""kind: conversation
name: {skill_id}-generated-smoke
description: {description}

turns:
  - user: {json.dumps(first_example["query"], ensure_ascii=False)}
    expect:
      skills: [{skill_id}]
      tool_calls: {tool_list}
"""


def preflight_writes(outputs: list[tuple[pathlib.Path, str]], force: bool) -> None:
    conflicts = [str(path) for path, _ in outputs if path.exists()]
    if conflicts and not force:
        formatted = "\n  ".join(conflicts)
        raise SkillKitError(f"refusing to overwrite existing files; pass --force:\n  {formatted}")


def render(manifest_path: pathlib.Path, output_root: pathlib.Path, force: bool = False) -> None:
    manifest = load_manifest(manifest_path)
    validate_manifest(manifest)

    skill_dir = output_root / "Skills" / "Library" / manifest["id"]
    scenario_dir = output_root / "PhoneClawCLI" / "Scenarios"
    outputs: list[tuple[pathlib.Path, str]] = []

    for locale, file_name in LOCALES.items():
        body = localized_body(manifest, locale)
        if not body:
            continue
        outputs.append((skill_dir / file_name, render_skill_file(manifest, locale)))
    outputs.append((scenario_dir / f"{manifest['id']}_generated_smoke.yaml", render_scenario(manifest)))

    preflight_writes(outputs, force)
    for path, content in outputs:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    print(f"rendered {manifest['id']} into {output_root}")


def usage() -> str:
    return (
        "Usage:\n"
        "  skillkit.py validate <manifest.json>\n"
        "  skillkit.py render [--force] <manifest.json> <output-dir>\n"
    )


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(usage(), file=sys.stderr)
        return 2

    command = argv[1]
    manifest_path = pathlib.Path(argv[2])
    try:
        if command == "validate":
            validate_manifest(load_manifest(manifest_path))
            print(f"valid: {manifest_path}")
            return 0
        if command == "render":
            args = argv[2:]
            force = False
            if args and args[0] == "--force":
                force = True
                args = args[1:]
            if len(args) != 2:
                print(usage(), file=sys.stderr)
                return 2
            render(pathlib.Path(args[0]), pathlib.Path(args[1]), force=force)
            return 0
    except SkillKitError as exc:
        print(f"skillkit: {exc}", file=sys.stderr)
        return 1

    print(usage(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
