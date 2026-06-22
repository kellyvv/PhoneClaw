# SkillKit

SkillKit is a draft generator for PhoneClaw skills. It is intentionally small and dependency-free so the contract can evolve before it becomes part of the app build.

## Current Commands

```sh
python3 Tools/SkillKit/skillkit.py validate Tools/SkillKit/examples/skill.json
python3 Tools/SkillKit/skillkit.py render Tools/SkillKit/examples/skill.json /tmp/phoneclaw-skillkit
python3 Tools/SkillKit/skillkit.py render --force Tools/SkillKit/examples/skill.json /tmp/phoneclaw-skillkit
```

`validate` checks the minimum Skill Contract V2 fields.

`render` creates:

- `SKILL.md`
- `SKILL.en.md`
- `SKILL.ja.md`
- `PhoneClawCLI/Scenarios/<skill-id>_generated_smoke.yaml`

The generated files are skeletons. They are meant to make new skills consistent, not to replace human review.
`render` refuses to overwrite existing files unless `--force` is passed.
Locale files are generated only when that locale has an explicit body; SkillKit does not fake translations by copying Chinese text into English or Japanese files.

## Manifest Shape

The draft manifest is JSON for now:

```json
{
  "id": "sample",
  "name": "Sample",
  "name_zh": "示例",
  "description": "Demonstrates the SkillKit skeleton.",
  "type": "device",
  "icon": "wrench",
  "version": "1.0.0",
  "disabled": false,
  "triggers": ["sample"],
  "allowed_tools": ["sample-query"],
  "examples": [
    {
      "query": "sample query",
      "scenario": "sample route"
    }
  ],
  "body": {
    "zh": "# 示例\n\n按契约处理请求。",
    "en": "# Sample\n\nHandle requests according to the contract.",
    "ja": "# サンプル\n\n契約に従ってリクエストを処理します。"
  }
}
```

## Future Work

- Generate prompt-pack fixtures.
- Generate AppIntent schema stubs.
- Generate `SkillContract` Swift fixtures.
- Validate `allowed_tools` against `ToolRegistry` snapshots.
- Add translation anchor generation for localized SKILL files.
