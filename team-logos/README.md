# Team logos

There is no upload and no per-team logo setting. A team’s logo file is looked
up by a fixed name derived from its short name:

    Short name    →  Logo file
    JETS          →  jets_logo.png
    ORŁY          →  orly_logo.png
    WILKI         →  wilki_logo.png

Rules:

  - PNG files only (that is the expected image type).
  - Use the lower-case, ASCII slug of the short name (ł → l, other diacritics
    stripped), then `_logo.png`.
  - Small, roughly square files look best (e.g. 200×200 px).
  - Put the file in this folder — no restart or data edit is needed.
  - If the file is missing, the web shows a neutral “no logo” crest and the
    printed protocol draws a placeholder box.

Snapshot export (Settings → Export) copies these logo files next to the
exported JSON, and import restores them from that same folder — so the whole
dump (JSON + images) can be moved to another machine.

Files without a matching team are ignored.
