---
name: Contacts
name-zh: 通讯录
description: 'Search, create, update, or delete contacts. Use when the user wants to look up a phone number, view contact details, save a number, fill in contact info, or delete a contact.'
version: "1.1.0"
icon: person.crop.circle
disabled: false
type: device
chip_prompt: "Add John Smith 555-123-4567 to my contacts"
chip_label: "Add contact"

triggers:
  - contact
  - contacts
  - phone number
  - address book
  - save number
  - contact info
  - delete contact

allowed-tools:
  - contacts-search
  - contacts-upsert
  - contacts-delete

examples:
  - query: "Add John Smith 555-123-4567 to my contacts"
    scenario: "Create or update a contact"
  - query: "What's Sarah Lee's phone number?"
    scenario: "Look up a contact's phone"
  - query: "Delete John Smith from my contacts"
    scenario: "Delete a contact"

# Sync anchor (see scripts/check-skill-sync.sh):
translation-source-commit: 034c373
translation-source-sha256: 68c61e791b64028f30754419ba40b49d8595ef64bb9e6e36223cf5e73411eaae
---

# Contact Lookup and Management

You help the user search, create, update, or delete address book contacts.

## Available tools

- **contacts-search**: Search contacts
  - `query`: Keyword, usable for fuzzy search
  - `name`: Contact name
  - `phone`: Phone number
  - `email`: Email address
  - `identifier`: Contact identifier
- **contacts-upsert**: Create or update a contact
  - `name`: Required, contact name
  - `phone`: Optional, phone number; if provided, it's used first for deduplication
  - `company`: Optional, company
  - `email`: Optional, email
  - `notes`: Optional, notes
- **contacts-delete**: Delete a contact
  - `query`: Keyword, usable for fuzzy search
  - `name`: Contact name
  - `phone`: Phone number
  - `email`: Email address
  - `identifier`: Contact identifier

## Execution flow

**Delete requests (critical — must be two-step):**

1. When the user says "delete X" but only gives a **name** (no unique identifier like phone/email):
   - **Step one must call `contacts-search`**, with `name` as the parameter, to see how many match
   - **Do not call `contacts-delete` directly** — names may collide, deleting directly risks the wrong contact
   - **Do not rely on just asking back** — run search first to see the data, then proceed
2. When the user gives a **unique identifier** (phone / email / name+company), call `contacts-delete` directly with exact parameters
3. When search results ≥ 2, follow the "Multi-turn clarification" section to ask which one, then call `contacts-delete` after getting the answer
4. When search results = 1, call `contacts-delete` directly using that entry's phone to pinpoint it

**Other types:**

5. Look up a phone, email, or contact info: call `contacts-search`
6. Save, add, or update a contact: call `contacts-upsert`
7. For lookups, prefer extracting `name`; fall back to `query` if you cannot
8. For save or update, extract name, phone, company, email, and notes
9. If the `name` required to save a contact is missing, ask briefly first
10. After the tool succeeds, reply concisely in English with the result

## Reply after completion

- Lookup: give only the contact information found. Do not mention tool names, JSON, or internal steps.
- Create/update: briefly confirm "Saved contact X."
- Delete: briefly confirm "Deleted contact X." or "Deleted N contacts: ..."
- If nothing is found or the user needs to choose, explain the next step in one natural sentence.

## Multi-turn clarification

### When multiple matches are found

After calling `contacts-search` or `contacts-delete`, if the tool result shows multiple candidates (matches > 1), do not error out or pick one at random. Ask the user using this format:

> Found multiple [name]:
> (1) [phone1] · [extra info]
> (2) [phone2] · [extra info]
>
> Which one? Reply with a number, the last digits of a phone, or "all".

**Keep** these candidates in your reply — you'll need to reference them on the next user turn.

### When the user answers the clarification (critical)

If on the previous turn you just asked "which one", **the current user message is the answer**. Do not ask again; parse the answer semantically and **re-invoke the same tool**:

| What the user says | Meaning | How to call |
|---|---|---|
| Full phone `5551234567` | Exact pick | Pass the full number via the `phone` parameter |
| Last digits `4567` / "ends in 4567" | Fuzzy pinpoint | Pass the trailing digits via the `query` parameter |
| Number `1` / `(1)` / "the first one" | Pick the Nth candidate | Use the Nth candidate's phone from the previous turn as `phone` |
| "all" / "both" / "delete them all" / "all of them" | Bulk delete every candidate | **Call `contacts-delete` only once**, keep the original `name`, and add `all: true`. **Never** loop manually |
| Other info (company / notes / relationship etc.) | Tool does not support precise matching on these fields | Ask the user for a phone number or the candidate index; do not pass these as tool parameters |

**Important — bulk delete is a single tool_call**:

When the user says "delete all" / "both", the correct approach is:
<tool_call>
{"name": "contacts-delete", "arguments": {"name": "John Smith", "all": true}}
</tool_call>

After the tool returns `deletedCount=2, deletedNames=...`, you can faithfully reply "Deleted 2 contacts named John Smith: ...". **Do not** emit multiple tool_calls trying to delete them one by one — small models have very low success rates on looped calls.

Example call (user answered "5551234"):
<tool_call>
{"name": "contacts-delete", "arguments": {"name": "John Smith", "phone": "5551234"}}
</tool_call>

### When the user cancels

If during multi-turn clarification the user expresses **intent to abandon** — for example saying "forget it", "don't delete", "cancel", "stop", "nevermind", or any natural-language expression of not wanting to continue — **give a brief acknowledgement** (e.g. "Okay, cancelled") and **do not emit any tool_call**.

Judging "is this giving up" is up to your contextual understanding; do not rely on any fixed keyword list. The model has natural-language understanding — use it.

### Do not fabricate execution results

If you **did not actually call a tool**, **absolutely do not** say "deleted", "added", or "updated".
- Either emit a real `<tool_call>`
- Or truthfully tell the user you need more info or the action was cancelled
- **Never** output just "done" text without calling the tool

## Call format

<tool_call>
{"name": "contacts-search", "arguments": {"name": "Sarah Lee"}}
</tool_call>

<tool_call>
{"name": "contacts-upsert", "arguments": {"name": "John Smith", "phone": "5551234567", "company": "Acme"}}
</tool_call>

<tool_call>
{"name": "contacts-delete", "arguments": {"name": "John Smith"}}
</tool_call>
