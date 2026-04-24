---
name: Translate
name-zh: 翻译
description: 'Professional translation assistant, supporting mutual translation between any languages.'
version: "1.1.0"
icon: character.bubble
disabled: false
type: content
chip_prompt: "Translate the following sentence into French: The weather is really nice today"
chip_label: "Translate"

triggers:
  - translate
  - translation
  - translated into
  - render into
  - Chinese to English
  - English to Chinese
  - translate as
  # Natural phrasings like "say X in Y language" also count as translation
  - in English
  - in Japanese
  - in Korean
  - in French
  - in German
  - in Spanish
  - say in Chinese

allowed-tools: []

examples:
  - query: "Translate the following sentence into English: 今天天气真好"
    scenario: "Chinese to English"
  - query: "translate to Chinese: The early bird catches the worm"
    scenario: "English to Chinese"
  - query: "Translate that previous passage into Japanese"
    scenario: "Referring to prior context"

# Sync anchor (see scripts/check-skill-sync.sh):
translation-source-commit: 034c373
translation-source-sha256: 89b5dfd5a5e9b071f81bb0fc73d5217134643dcd0d2aa4254c8aa7ea55e372f7
---

# Professional Translation

Output the translation directly, with no prefix, no explanation of the process, and no alternatives listed.

## Identifying the Source Text

1. If the user's message contains content inside quotation marks or after a colon → take that segment
2. If the user uses a referring expression such as "this passage / that passage just now / the above / the preceding" → take the body of the most recent assistant message in the conversation history (skipping warning lines like "Warning" and single-sentence acknowledgements like "Okay")
3. If none of the above applies → only then may you ask back "Please provide the text to translate"

## Identifying the Target Language

- User explicitly specifies (e.g. "translate into English") → follow the user's request
- User asks "what does this mean" → default to translating into Chinese
- Source text is Chinese and target is unspecified → default to translating into English

## Translation Principles

**Faithfulness, Expressiveness, Elegance**: faithful to the original meaning + conforming to the target language's grammar and conventions + matching the register of the original (formal / colloquial / literary / technical).

Specifically:
- Use equivalent expressions for idioms rather than literal translations ("画蛇添足" → "gild the lily")
- In Chinese-to-English, supply omitted subjects; in English-to-Chinese, omit them following Chinese convention
- For Japanese/Korean → Chinese/English, adjust SOV→SVO word order
- Use the target language's punctuation system (full-width for Chinese, half-width for English)
- Proper nouns (personal names / place names / brands) are kept as-is or rendered with the conventional accepted translation

## Output

Output only the translated text itself. When the source text is ambiguous and needs context to clarify, give the most likely translation first, then in a following short paragraph add a single line noting "Another possible reading is ...".
