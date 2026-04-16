#!/usr/bin/env python3
"""
Register the 8 new .swift files (Live Turn processor + LiveVoice prompt extension)
into PhoneClaw.xcodeproj/project.pbxproj.

Uses sourceTree = SOURCE_ROOT so paths are relative to project root, and
anchors to the OutputCleaner entries (already present) for stable insertion.
"""
import os, re, hashlib, sys

PROJ_DIR = "/Users/zxw/AITOOL/PhoneC"
PBXPROJ = os.path.join(PROJ_DIR, "PhoneClaw.xcodeproj", "project.pbxproj")

FILES_TO_ADD = [
    "Live/Turn/Types/LiveMarker.swift",
    "Live/Turn/Types/LiveHistoryMessage.swift",
    "Live/Turn/Types/LiveSkillCall.swift",
    "Live/Turn/Types/LiveOutputEvent.swift",
    "Live/Turn/LiveOutputParser.swift",
    "Live/Turn/LiveTurnProcessor.swift",
    "LLM/LiveVoice/LiveLocale.swift",
    "LLM/LiveVoice/LiveVoiceConstants.swift",
    "LLM/LiveVoice/PromptBuilder+LiveVoice.swift",
]

def make_uuid(seed):
    return hashlib.md5(seed.encode()).hexdigest().upper()[:24]

def main():
    if not os.path.exists(PBXPROJ):
        print(f"ERROR: {PBXPROJ} not found"); sys.exit(1)

    for f in FILES_TO_ADD:
        if not os.path.exists(os.path.join(PROJ_DIR, f)):
            print(f"ERROR: {f} not found on disk"); sys.exit(1)

    with open(PBXPROJ, "r") as fh:
        content = fh.read()

    # Skip already-registered files (basename match)
    files = [f for f in FILES_TO_ADD if os.path.basename(f) not in content]
    if not files:
        print("All files already registered. Nothing to do."); return

    existing_uuids = set(re.findall(r'\b([0-9A-F]{24})\b', content))
    def safe_uuid(seed):
        u = make_uuid(seed)
        i = 0
        while u in existing_uuids:
            i += 1; u = make_uuid(seed + str(i))
        existing_uuids.add(u)
        return u

    entries = []
    for f in files:
        bn = os.path.basename(f)
        entries.append({
            "path": f,
            "basename": bn,
            "fileref": safe_uuid(f"fileref_{f}_liveturn"),
            "buildfile": safe_uuid(f"buildfile_{f}_liveturn"),
        })

    # Anchors — all point to OutputCleaner.swift, which is a stable entry
    # in Agent/Engine/ that won't move.
    anchor_bf  = re.compile(r'(\t\tA31476FB2F85741500318978 /\* OutputCleaner\.swift in Sources \*/ = \{[^}]+\};)\n')
    anchor_fr  = re.compile(r'(\t\tA31476EF2F85741500318978 /\* OutputCleaner\.swift \*/ = \{[^}]+\};)\n')
    anchor_sp  = re.compile(r'(\t\t\t\tA31476FB2F85741500318978 /\* OutputCleaner\.swift in Sources \*/,)\n')
    anchor_grp = re.compile(r'(\t\tD21E6B56B839A63857912FE0 /\* PhoneClaw \*/ = \{\s*\n\t\t\tisa = PBXGroup;\s*\n\t\t\tchildren = \(\n)')

    for name, pat in [("PBXBuildFile", anchor_bf), ("PBXFileReference", anchor_fr),
                      ("Sources", anchor_sp), ("Group", anchor_grp)]:
        if not pat.search(content):
            print(f"ERROR: anchor not found for {name}"); sys.exit(1)

    # 1. PBXBuildFile
    lines = "\n".join(
        f'\t\t{e["buildfile"]} /* {e["basename"]} in Sources */ = '
        f'{{isa = PBXBuildFile; fileRef = {e["fileref"]} /* {e["basename"]} */; }};'
        for e in entries
    ) + "\n"
    m = anchor_bf.search(content)
    content = content[:m.end()] + lines + content[m.end():]

    # 2. PBXFileReference
    lines = "\n".join(
        f'\t\t{e["fileref"]} /* {e["basename"]} */ = '
        f'{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
        f'name = "{e["basename"]}"; path = "{e["path"]}"; sourceTree = SOURCE_ROOT; }};'
        for e in entries
    ) + "\n"
    m = anchor_fr.search(content)
    content = content[:m.end()] + lines + content[m.end():]

    # 3. Sources build phase
    lines = "\n".join(
        f'\t\t\t\t{e["buildfile"]} /* {e["basename"]} in Sources */,'
        for e in entries
    ) + "\n"
    m = anchor_sp.search(content)
    content = content[:m.end()] + lines + content[m.end():]

    # 4. PhoneClaw group children
    lines = "\n".join(
        f'\t\t\t\t{e["fileref"]} /* {e["basename"]} */,'
        for e in entries
    ) + "\n"
    m = anchor_grp.search(content)
    content = content[:m.end()] + lines + content[m.end():]

    with open(PBXPROJ, "w") as fh:
        fh.write(content)

    print(f"Added {len(entries)} files to PBX project:")
    for e in entries:
        print(f"  + {e['path']}")

if __name__ == "__main__":
    main()
