#!/usr/bin/env python3
"""Generate emoji-data.js from GitHub gemoji.

This script produces the EMOJI_DATA JavaScript object used by the
emoji autocomplete feature in Galaxy's WKWebView annotation textareas.
It reads GitHub's gemoji dataset and outputs a JS file with two maps:
  - map:  shortcode -> emoji character  (~1,900 entries)
  - tags: shortcode -> search tags      (~470 entries)

The output file is committed to the repo. The gemoji source is NOT
vendored or submoduled — you download it fresh each time you regenerate.

Source: https://github.com/github/gemoji
  The canonical dataset GitHub uses for :shortcode: emoji resolution.
  Updated when the Unicode Consortium ratifies new emoji (roughly once
  a year, ~20-30 new emoji per release). No maintenance cadence needed;
  regenerate when you notice a missing emoji.

Output: GalaxyApp/GalaxyApp/Resources/emoji-data.js
  The output path is relative to this script's location and resolves
  correctly regardless of your working directory.

How to regenerate:

  # 1. Download the gemoji source (no need to clone the full repo)
  curl -sL https://raw.githubusercontent.com/github/gemoji/master/db/emoji.json \\
       -o /tmp/gemoji-emoji.json

  # 2. Run this script
  python3 GalaxyApp/scripts/generate-emoji-data.py /tmp/gemoji-emoji.json

  # 3. Verify output
  #    Script prints entry counts. Expect ~1,900 shortcodes, ~470 tags.
  #    The output file is GalaxyApp/GalaxyApp/Resources/emoji-data.js.

  # 4. Rebuild the app
  #    The JS file is a bundle resource — Xcode copies it into the app
  #    on build. No additional project changes needed.

Initial generation (2026-02-28):
  Source: github/gemoji master as of 2026-02-28
  Result: 1,913 shortcode entries, 472 tag entries, ~77KB output file
"""

import json
import sys
import os


def main():
    if len(sys.argv) < 2:
        print("Usage: generate-emoji-data.py <path-to-gemoji-emoji.json>")
        sys.exit(1)

    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        gemoji = json.load(f)

    emoji_map = {}
    tags_map = {}

    for entry in gemoji:
        emoji = entry.get('emoji')
        if not emoji:
            continue  # Skip entries without unicode (custom GitHub emoji)

        aliases = entry.get('aliases', [])
        tags = entry.get('tags', [])

        for alias in aliases:
            emoji_map[alias] = emoji

        # Store tags for the primary alias only
        if aliases and tags:
            tags_map[aliases[0]] = tags

    # Generate JS
    output_path = os.path.join(
        os.path.dirname(__file__),
        '..', 'GalaxyApp', 'Resources', 'emoji-data.js'
    )

    with open(output_path, 'w', encoding='utf-8') as f:
        f.write('// emoji-data.js — Generated from GitHub gemoji\n')
        f.write('// Do not edit manually. Regenerate with scripts/generate-emoji-data.py\n\n')
        f.write('const EMOJI_DATA = {\n')
        f.write('  map: ')
        f.write(json.dumps(emoji_map, ensure_ascii=False, indent=4))
        f.write(',\n\n  tags: ')
        f.write(json.dumps(tags_map, ensure_ascii=False, indent=4))
        f.write('\n};\n')

    print(f"Generated {output_path}")
    print(f"  {len(emoji_map)} shortcode entries")
    print(f"  {len(tags_map)} tag entries")


if __name__ == '__main__':
    main()
