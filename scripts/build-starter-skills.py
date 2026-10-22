#!/usr/bin/env python3
"""Packs starter-skills/<name>/SKILL.md into leanring-buddy/DottieStarterSkills.json,
the one file the app bundles (Xcode copies it as a resource; folders of
same-named SKILL.md files would collide). Run it after editing a skill."""
import json
import pathlib

repository_root = pathlib.Path(__file__).resolve().parent.parent
skills_folder = repository_root / "starter-skills"
output_file = repository_root / "leanring-buddy" / "DottieStarterSkills.json"

starter_skills = []
for skill_file in sorted(skills_folder.glob("*/SKILL.md")):
    starter_skills.append({"name": skill_file.parent.name, "text": skill_file.read_text(encoding="utf-8")})

output_file.write_text(json.dumps(starter_skills, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
print(f"wrote {len(starter_skills)} skills to {output_file.relative_to(repository_root)}")
