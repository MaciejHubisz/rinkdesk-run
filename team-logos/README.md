# Team logos

There is no upload and no per-team logo setting. A team’s logo is matched to a
file in this folder by its short name.

    Short name    →  Matching file (any of these)
    JETS          →  jets_logo.png   jets.png   Jets.JPG   jets logo.webp
    ORŁY          →  orly_logo.png   orly.jpg   ORŁY.svg
    WILKI         →  wilki_logo.png  wilki.webp

Rules:

  - Matching ignores case, diacritics (ł → l, ó → o, …), spaces and `_`/`-`,
    and the optional `logo` word. The file just has to start with the short
    name’s slug.
  - PNG, JPG/JPEG, WEBP, GIF, BMP, AVIF and SVG are accepted.
  - Small, roughly square files look best (e.g. 200×200 px).
  - Put the file in this folder — no restart or data edit is needed.
  - If no file matches, the web shows a neutral “no logo” crest and the printed
    protocol draws a placeholder box.

Snapshot export (Settings → Export) copies these logo files next to the
exported JSON, and import restores them from that same folder — so the whole
dump (JSON + images) can be moved to another machine.

Files that do not match any team are ignored.
