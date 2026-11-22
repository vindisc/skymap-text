# UI scripts

Headless UI captures for SkyBook, ported from upstream MiaoYan's harness.
`Helpers/UIScript.swift` (Debug builds only) runs a line-per-command script
against the shell window and writes PNG captures; `scripts/ui_script.py`
launches it in the background on a scratch copy of
`library/`, then — in `compare` mode — diffs two builds' captures pixel by
pixel, so a refactor that must not change the look proves it.

    python3 scripts/ui_script.py run .build/SkyBook.app scripts/ui_scripts/smoke.txt --out /tmp/smoke
    python3 scripts/ui_script.py compare old.app new.app scripts/ui_scripts/smoke.txt --out /tmp/smoke

`smoke.txt` opens both fixture notes, types into one, and captures the
editor, the outline and the preview. `bench.txt` needs the generated
Medium/Large notes: `python3 scripts/ui_scripts/gen_bench_library.py` writes
them next to the fixtures, then point `--library` at that folder.

The scratch library means the real notes are never opened; `-storageUrl`
points the run at the copy. A Release build has no UIScript, so a run
against one reports "no script.log".
