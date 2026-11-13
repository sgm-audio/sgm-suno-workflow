# Audit, QA and Verification Report

**Repository**: `sgm-audio/sgm-suno-workflow` (Suno AI Workflow Suite for REAPER)
**Branch**: `arena/fe316ea1-sgm-suno-workflow`
**Date**: 2026-11-13
**Scope**: all seven Lua scripts, the ReaPack index, the bundle metapackage, documentation and CI
**Method**: verification against the official REAPER API surface, the official ReaTeam script corpus, and the ReaPack source; plus a purpose-built offline test harness, static API checks and a linter.

---

## 1. Executive summary

The suite had **two blocking defects that made 4 of 6 scripts fail on every run**, plus several that silently produced wrong output. None of them were detectable with the previous CI, which only ran `luac -p` (syntax).

| | Before | After |
|---|---|---|
| Scripts that can complete a run | 2 of 6 | 6 of 6 |
| Automated assertions | 0 | **223 passing** |
| Files lint-clean (undefined globals / unused locals / deprecated API) | not measured | **18 of 18** |
| `reaper.*` calls verified against the official API list | 0 | **all** (877-function list) |

The three headline findings:

1. **`MediaItemTake_GetPeaks` does not exist.** The real function is `GetMediaItemTake_Peaks` with a different signature. `Suno_02_TempoMapper`, `Suno_03_DynamicSplitter` and `Suno_04_LoudnessMaster` therefore aborted at their first peak read. Even after renaming, the buffer handling was wrong in three independent ways (bit-packed return value, two-block layout, project-time offset).
2. **`reaper.GetTempPath()` does not exist.** `SGM_Suno ZIP Importer` failed the moment you pressed *Import into REAPER!*.
3. **The splitter's sensitivity was inverted** relative to its own prompt and the README, so tuning it made results move the wrong way.

Everything listed in §5 has been fixed and has a regression test.

---

## 2. What "verified against the official API" means here

Rather than rely on memory, each API claim was checked against a primary source:

| Source | Used for |
|---|---|
| [`justinfrankel/reaper-sdk`](https://github.com/justinfrankel/reaper-sdk) → `sdk/reaper_plugin_functions.h` (current `main`) | The 877 exported ReaScript function names and their exact C signatures/return semantics. Extracted mechanically into `tests/reaper_api_names.txt`. |
| [`ReaTeam/ReaScripts`](https://github.com/ReaTeam/ReaScripts) index + scripts | Authoritative usage patterns: `GetMediaItemTake_Peaks` buffer layout and `retval & 0xFFFFF` masking, `<source main="main">` index syntax, package naming, metapackage `@provides`. |
| [`cfillion/reapack`](https://github.com/cfillion/reapack) source (`src/source.cpp`, `src/index_v1.cpp`, `src/install.cpp`) | How `<source file=…>` / package `name` map to installed files, and that `Source::file()` falls back to the package name. |
| [`cfillion/reaimgui`](https://github.com/cfillion/reaimgui) | ReaImGui call shapes used by the importer (`ImGui_ProgressBar`, `BeginChild`, flag enums as functions → 0.9+). |

Two API facts that drove most of the fixes:

```c
// reaper_plugin_functions.h
int GetMediaItemTake_Peaks(MediaItem_Take*, double peakrate, double starttime,
                           int numchannels, int numsamplesperchannel,
                           int want_extra_type, double* buf);
// "peak samples are interleaved, but in two or three blocks (maximums, then
//  minimums, then extra). Return value has 20 bits of returned sample count,
//  then 4 bits of output_mode (0xf00000), then a bit ... (0x1000000)."
```

There is no `GetTempPath` export and no `MediaItemTake_GetPeaks` export in the header (nor in any ReaScript-only addition).

---

## 3. Severity legend

| Level | Meaning |
|---|---|
| **P0** | The script cannot complete a run. |
| **P1** | Runs, but produces wrong results or damages the user's project. |
| **P2** | Robustness / security / UX defect in realistic edge cases. |
| **P3** | Packaging, documentation or code hygiene. |

---

## 4. Findings index

| ID | Sev | Area | Finding |
|---|---|---|---|
| A1 | P0 | 02/03/04 | Peak call uses non-existent `MediaItemTake_GetPeaks` |
| A2 | P0 | ZIP | `reaper.GetTempPath()` does not exist |
| A3 | P0 | 02/03/04 | Peak `retval` is bit-packed; used raw as a sample count |
| A4 | P0 | 02/03/04 | Peak buffer read as channel-major; it is max-block then min-block |
| A5 | P0 | 02/03/04 | Peak `starttime` passed as `0` instead of project time |
| B1 | P1 | 03 | Sensitivity inverted vs prompt and docs |
| B2 | P1 | 04 | Loudness estimated from window peaks (biased, and now measured properly) |
| B3 | P1 | 01 | Suno ID not stripped when it precedes the stem |
| B4 | P1 | 01 | One duplicate region per stem track |
| B5 | P1 | 05 | Bus silently skipped when folders are disabled |
| B6 | P1 | 05 | Folder swallows other songs' tracks (non-adjacent groups) |
| B7 | P1 | 05 | Blind `I_FOLDERDEPTH = -1` can corrupt an existing hierarchy |
| B8 | P1 | 02 | "Guard" tempo marker repeated the new BPM — a no-op |
| B9 | P1 | 01/02/03/04 | Empty prompt field shifts every following parameter |
| C1 | P2 | ZIP | Shell command injection via the ZIP filename |
| C2 | P2 | ZIP | `\uXXXX` escapes not decoded; `json_string` can return the wrong value |
| C3 | P2 | ZIP | Audio discovery misses `.m4a`/`.flac`; pattern is fragile |
| C4 | P2 | ZIP | Temp folder not cleaned on error paths |
| C5 | P2 | ZIP | Empty folder track left open if no stem imports |
| C6 | P2 | ZIP | `lfs` read as an undeclared global |
| C7 | P2 | ZIP | Dead `cancel` path (no way to trigger it) |
| C8 | P2 | 05 | Failed `CreateTrackSend` (-1) used as a send index |
| D1 | P3 | index.xml | Package names lack the `.lua` extension |
| D2 | P3 | index/bundle | Bundle `@provides` paths had no matching `<source file=…>` |
| D3 | P3 | ZIP | Invalid `@provides [main] .` on a non-metapackage |
| D4 | P3 | 02 | `AddTempoTimeSigMarker` is deprecated |
| D5 | P3 | all | Dead locals (`SCRIPT_VERSION`, `ceiling_lin`, `target_lin`, `fname_lower`) |
| D6 | P3 | docs | README/test-cases contradicted the implementation (sensitivity, REAPER version, LUFS) |
| D7 | P3 | CI | Only syntax was checked — this is *why* A/B/C slipped through |

---

## 5. Detailed findings

### A1 — `MediaItemTake_GetPeaks` does not exist (P0)

**Where**: `Suno_02_TempoMapper.lua`, `Suno_03_DynamicSplitter.lua`, `Suno_04_LoudnessMaster.lua`.

**Evidence**: `grep` of the official `reaper_plugin_functions.h` returns no such symbol; the API is `GetMediaItemTake_Peaks`. `tests/reaper_api_names.txt` (generated from that header) flagged all three files immediately.

**Impact**: in REAPER this is `attempt to call a nil value (field 'MediaItemTake_GetPeaks')` — every run of the tempo mapper, splitter and loudness master died before doing anything. The script guards, dialogs and README all implied these worked.

**Fix**: renamed to `GetMediaItemTake_Peaks` in all three scripts, wrapped in a local `fetch_peaks()` helper.

**Regression test**: `test_a_static` (API-name check) + the three behaviour suites, which now exercise real audio.

---

### A2 — `reaper.GetTempPath()` does not exist (P0)

**Where**: `Various/SGM_Suno ZIP Importer.lua`, in `do_import()`.

**Impact**: the ZIP importer opened, let you pick a file, and then failed on import with `attempt to call a nil value (field 'GetTempPath')` — i.e. the flagship feature of the suite never worked. `TEST_CASES.md` TC-ZIP-01 was marked as a validation target but could never have passed.

**Fix**: `temp_base()` resolves `TEMP` / `TMP` / `TMPDIR`, falling back to `/tmp` (POSIX) or `%WINDIR%\Temp` (Windows).

**Regression test**: `test_zip_importer` — the whole import pipeline now runs end-to-end (7 cases).

---

### A3–A5 — Peak buffer semantics (P0)

Renaming the function alone would not have been enough; the reads were wrong in three independent ways. These are the kind of bug that survives because the code "looks right".

**A3 — bit-packed return value.** The `int` return carries the sample count in its low 20 bits plus output-mode/extra-type flags above. Using it directly as `n` produces an astronomically large loop bound (`for s = 1, n`) and buffer indices beyond the allocation.

```lua
-- before
local n = reaper.MediaItemTake_GetPeaks(...)   -- includes flag bits
-- after
local n = ret & 0xFFFFF
if n > nsamples then n = nsamples end
```

**A4 — buffer layout.** The buffer is *not* channel-major (`buf[c*n + s]`). It is two blocks of `chans*nsamples` doubles: all maximums (interleaved per channel), then all minimums. The old indexing read the minimums block as if it were channel 1's peaks.

```lua
-- after: peak amplitude of frame s, channel c
local base = (s - 1) * num_chans + (c - 1)
local hi = buf[base + 1]
local lo = buf[num_chans * nsamples + base + 1]
if lo < 0 then lo = -lo end
```

**A5 — start time.** `starttime` is a **project** time. Passing `0` analyses whatever is at 0 s. For an item at 0 s it works by accident; anywhere else the script measured the wrong audio (usually silence). Verified against official ReaTeam usage (`saull_Peak envelope generator.lua` passes `GetMediaItemInfo_Value(item,"D_POSITION")`).

```lua
-- after
local buf, n = fetch_peaks(take, item_pos, PEAKRATE, num_chans, n_req)
```

The test suite pins this with an item placed at 10 s (`test_02_tempo`) and 4 s (`test_03_splitter`); both fail against the old code.

---

### B1 — Splitter sensitivity inverted (P1)

The prompt says `0.1=loose  1.0=strict`, the README says "lower values = more splits", and the script's own `@about` says "lower = more splits". The code did the opposite:

```lua
local mult = 6.0 - clamp(sensitivity, 0.1, 1.0) * 4.0   -- 0.1 → 5.6 (strict), 1.0 → 2.0 (loose)
```

**Impact**: users tuning by the documented meaning moved results the wrong way. `TEST_CASES.md` TC-DS-02 encoded the *implementation* (low = fewer splits), contradicting the prompt in the same file.

**Fix**: `mult = 2.0 + sens * 4.0` (same numeric range, correct direction), plus corrected docs and test case.

**Regression test**: `test_03_splitter` — "higher sensitivity splits less (strict), lower splits more (loose)" asserts `loose >= strict` and `loose > 0`.

---

### B2 — Loudness measured from window peaks (P1)

The old code computed `RMS ≈ sqrt(mean(peak²))` over a 100 Hz peak cache. A peak cache stores window **maximums**, so the "RMS" is systematically high (often 2–4 dB), and the ceiling check used only the positive peaks.

**Fix**: `measure_with_accessor()` streams the item's real samples via `CreateTakeAudioAccessor` + `GetAudioAccessorSamples` in 32 768-sample blocks, computing true RMS (mono downmix) and true sample peak (`max |max|, |min|`). The peak-cache path remains as a fallback with the corrected API usage.

**Honesty note**: RMS ≠ LUFS (no K-weighting, no gating) and sample peak ≠ true peak. The README, script header and test cases now say so instead of implying a LUFS measurement.

**Regression test**: `test_04_loudness` — a 0.5-amplitude sine must land within 0.5 dB of −18 dBFS RMS; a −1 dBFS target on hot material must clamp the peak to exactly −0.3 dBFS.

---

### B3 — Suno ID not stripped when it precedes the stem (P1)

`MySong_abc123def456_vocals.wav` became `MySong abc123def456 [Vocals]` because the trailing-ID regex only looked at the last segment. The fix strips a trailing ID, then the stem, then a trailing ID again — covering both `Song_vocals_<id>` and `Song_<id>_vocals`.

**Regression test**: `test_01_metadata` — "handles the Suno ID before the stem suffix".

---

### B4 — Duplicate regions per stem track (P1)

Regions were added inside the per-track loop, so importing 4 stems of one song produced 4 identical overlapping regions with the same name. Now deduplicated per `(name, span)`.

**Regression test**: `test_01_metadata` — "creates one region per song span, not one per stem track".

---

### B5 — Bus skipped when folders are disabled (P1)

Bus creation was nested inside `if do_folder then …`, so answering "folder = no, bus = yes" silently did nothing. The bus is now independent of the folder and is placed directly after the group's last stem.

**Regression test**: `test_05_stems` — "a bus is still created when folders are disabled".

---

### B6 — Folder swallows other songs' tracks (P1)

The changelog for 1.0.2 claimed the folder/bus indexing was "safe for interleaved groups". It was safe for *indices* but not for *meaning*: `I_FOLDERDEPTH = 1` at `min_idx` and `-1` at `max_idx` folds **everything in between** into the folder, including other songs' tracks — a routing change the user never asked for.

**Fix**: folder creation now requires the group's tracks to occupy a contiguous span; otherwise the group is still aligned/renamed/coloured and gets a console warning.

**Regression test**: `test_05_stems` — "does not wrap another song's track in a folder".

---

### B7 — Blind folder-depth write (P1)

`SetMediaTrackInfo_Value(last_track, "I_FOLDERDEPTH", -1)` overwrote whatever was there. On a track that already closed an outer folder (`-1`) this closed two levels. Groups whose tracks already carry a non-zero depth are now skipped with a warning, and a folder that cannot be closed is reverted so the project is never left unbalanced.

**Regression test**: `test_05_stems` — "leaves an existing folder hierarchy untouched" and the global `folder_balance() == 0` assertions.

---

### B8 — Guard tempo marker was a no-op (P1)

The "guard" marker re-inserted the *new* BPM at the item end, which changes nothing — the new tempo simply continues. It now restores the tempo/time signature captured at the item start (via `tempo_at()`), so following songs keep their own tempo. The summary dialog reports the restored value.

**Regression test**: `test_02_tempo` — "guard marker restores the previous project tempo after the item".

---

### B9 — Prompt parsing shifts on empty fields (P1)

```lua
for p in csv:gmatch("[^,]+") do ... end   -- skips empty fields
```

Clearing one field silently re-mapped every later field (e.g. a blank sensitivity became the time signature). Replaced with `parse_numbers(csv, count)`, which keeps positions.

**Regression test**: `test_03_splitter` — "empty parameter fields do not shift the other settings".

---

### C1 — Shell command injection via the ZIP filename (P2)

`unzip -Z1 "%s"`, `unzip -o "%s" -d "%s"`, `rm -rf "%s"` and friends interpolated user-controlled paths into `sh` command lines with only `"` escaping. A file named `$(rm -rf ~).zip` executes on import. Only the *temp folder* was sanitised.

**Fix**: `sh_quote()` (single-quote with `'\''` escaping) for every POSIX command; the temp folder component is sanitised to `[%w%-_%.]`; the Windows double-quote guard is retained.

**Regression test**: `test_zip_importer` — "a ZIP filename with shell metacharacters is neutralised" strips single-quoted regions from every recorded shell command and asserts no live `$(`, backtick or separator remains.

---

### C2 — JSON reader (P2)

`json_string` advanced to the next `"` after the key, so a non-string value (`null`, a number) returned some *later* string in the file. `\uXXXX` escapes were emitted literally (`\u00e9` → `u00e9`), corrupting non-ASCII titles and lyrics.

**Fix**: the key pattern now requires a string value, and `\uXXXX` (including UTF-16 surrogate pairs) is decoded to UTF-8.

**Regression test**: `test_zip_importer` — `"Caf\u00e9 \u00dcber"` → `Café Über`.

---

### C3 — Audio format discovery (P2)

`find_files(dir, "%.[mw][p3av]+$")` matches `.mp3`/`.wav` but not `.m4a`, `.flac`, `.ogg`, `.opus`, `.aif(f)`. A Suno ZIP with `.m4a` stems reported "No audio files found".

**Fix**: explicit extension whitelist.

**Regression test**: `test_zip_importer` — "accepts .m4a and .flac".

---

### C4/C5 — Cleanup and folder balance on failure (P2)

- The temp folder leaked on the "extraction failed" and "no audio" paths. Now a single `cleanup()` runs on all paths.
- If every stem failed to import, the folder track stayed open (depth 1). Now the depth is reset to 0 and a warning is logged.

**Regression test**: `test_zip_importer` — "temp folder is always cleaned up"; folder balance asserted in the main import case.

---

### C6 — `lfs` was an undeclared global (P2)

`if lfs then …` read a global nobody declared. It works only because SWS happens to inject `lfs`. Now resolved explicitly with `pcall(require, "lfs")` and a `_G.lfs` fallback, and the new linter would flag a regression.

---

### C7 — Dead cancel path (P2)

`state.cancel` was never set (there is no Cancel button), so the cancellation branch, the `cancelled` flag and its ternaries were unreachable. Removed; the undo block is still balanced on every path.

---

### C8 — Failed send used as an index (P2)

`CreateTrackSend` returns `-1` on failure; that value was passed straight to `SetTrackSendInfo_Value`. Now `create_post_fader_send()` checks the index and the bus reports `routed/total`.

---

### D1 — Package names missing `.lua` (P3, but user-visible)

ReaPack derives the installed path from `<source file=…>`, and `Source::file()` falls back to the **package name** when the attribute is absent:

```cpp
const std::string &Source::file() const {
  if(!m_file.empty()) return m_file;
  else                return m_version->package()->name();
}
```

All seven packages were named without an extension, so ReaPack installed `Scripts/<repo>/<category>/Suno_01_MetadataOrganizer` — a file REAPER cannot load as a ReaScript. Every package in the official ReaTeam index carries a real extension (788 `.lua`, 95 `.eel`, 0 extension-less).

**Fix**: all package names now end in `.lua`; INSTALL.md documents the migration for existing users (the old extension-less files should be deleted).

---

### D2 — Metapackage `@provides` resolved to nothing (P3)

`@provides [main] Various/SGM_Suno ZIP Importer.lua` etc. must name a file that is part of the package. The bundle's version declared a *single* source (the bundle's own file), so none of the six provided paths existed. The bundle therefore provided nothing.

**Fix**: the bundle's version now lists all provided files as `<source main="main" file="…">` entries, matching `@provides` one-for-one (the same multi-file pattern the official `talagan_Mouse cursor library.lua` metapackage uses).

**Regression test**: `test_a_static` — "bundle @provides paths are declared as package sources", plus "every package name carries a .lua extension".

---

### D3–D5 — Metadata and hygiene

- Removed `-- @provides [main] .` from the ZIP importer (only metapackages use `@provides`, and `.` is not a valid path).
- `AddTempoTimeSigMarker` is documented as deprecated → switched to `SetTempoTimeSigMarker(0, -1, …)`.
- Removed dead locals the new linter found: `SCRIPT_VERSION` (unused in 02/04), `ceiling_lin`, `target_lin`, the unused `fname_lower` parameter in `Suno_05`.

---

### D6 — Documentation contradicted the code (P3)

| Document | Claim | Reality |
|---|---|---|
| README badge / tables | REAPER 7.0+ | code enforces 6.70 |
| README (script 3) | "lower values = more splits" | code did the opposite (now true) |
| `TEST_CASES.md` TC-DS-02 | "low sensitivity → fewer splits" | contradicted the prompt in the same file |
| header examples | `"my-song (v2)_abcdef.mp3"` → "my song (v2)" | 6-char IDs are not Suno IDs (8–32), so the ID stayed |
| README (script 4) | "-14 LUFS" | targets dBFS RMS; not LUFS |
| INSTALL.md | "ReaImGui latest" | flag enums as functions require 0.9+ |

All corrected.

---

### D7 — CI only checked syntax (P3, root cause)

`luac -p` cannot see a call to a function that does not exist, a wrong buffer layout, an inverted threshold, or a broken package name. That is exactly the set of defects found. CI now runs syntax, lint, API verification and behaviour tests.

---

## 6. Verification performed

### 6.1 New offline harness — `tests/`

A mock of the ReaScript API that is deliberately **faithful to the documented semantics**, rather than forgiving:

| Behaviour modelled | Why it matters |
|---|---|
| `GetMediaItemTake_Peaks`: bit-packed `retval`, maximums-then-minimums blocks, interleaved channels, project-time `starttime` | Reproduces A3/A4/A5 instead of hiding them |
| `reaper.array` with bounds tracking | Any out-of-range read sets `P.oob`, asserted by the suites |
| `SplitMediaItem` returns the **right** item and keeps the left handle | Verifies right-to-left splitting |
| `I_FOLDERDEPTH` balance helper | Verifies folders always open and close |
| `CreateTrackSend` returning `-1`/indices, `I_SENDMODE` | Verifies bus routing |
| `GetUserInputs` queue incl. `@default` (press OK) and cancel | Exercises both prompt paths |
| `os.execute` / `io.popen` / `io.open` / `lfs` sandbox with a ZIP materialiser | End-to-end import without touching the real filesystem |
| ImGui stubs where buttons "click themselves" | Drives the real GUI loop, including `do_import()` |
| Unknown `reaper.<Name>` returns nil | A missing API fails exactly like it would in REAPER |

```
test_a_static         29 assertions   syntax, API names, ReaPack metadata
test_01_metadata      34              filename parsing, colours, regions, scope
test_02_tempo         24              BPM detection, override, guard marker, silence
test_03_splitter      23              boundaries, contiguity, naming, sensitivity
test_04_loudness      15              RMS targets, ceiling clamp, silent items
test_05_stems         45              grouping, alignment, folders, buses, interleaving
test_zip_importer     49              import, zip-slip, injection, JSON, cleanup, no-ImGui
                     ---
                     223 assertions, 0 failures
```

### 6.2 Static analysis — `tools/lua_lint.py`

A dependency-free Lua linter (tokenizer + scope walker) reporting:

* undefined globals (the `lfs` class of bug, and plain typos),
* unused locals,
* deprecated / non-existent API calls (`AddTempoTimeSigMarker`, `MediaItemTake_GetPeaks`, `GetTempPath`).

```
$ python3 tools/lua_lint.py *.lua Various/*.lua tests/*.lua
lint OK (18 file(s))
```

### 6.3 API surface check

Every `reaper.X` reference in every script is compared against `tests/reaper_api_names.txt` (877 official exports + 3 ReaScript-only additions). Extensions (`ImGui_*`, `gfx_*`, `SWS_*`, `CF_*`) are exempted by prefix. This check alone catches A1 and A2.

### 6.4 Manual-equivalence notes

The harness cannot validate: actual audio decoding, ReaImGui rendering/layout, PowerShell/`unzip` behaviour, or ReaPack's install. Those remain manual, and `TEST_CASES.md` now names the automated counterpart for each case so a tester knows what is left to check by hand.

---

## 7. Not verifiable offline (residual risk)

| Item | Risk | Mitigation |
|---|---|---|
| ReaPack install path resolution | Medium — depends on the index fix (D1/D2) | Confirmed against `reaper-sdk`/ReaPack source and the official index; needs one live install test |
| ReaImGui 0.9 API shape | Low | Signatures checked against `imgui.h`/ReaImGui; constants-as-functions documented as a 0.9+ requirement |
| `GetAudioAccessorSamples` performance on very long items | Low | 32 768-frame blocks; accessor destroyed on all paths |
| Chinese/Japanese filenames on Windows (PowerShell listing) | Low | Unchanged from before; the importer falls back to `Expand-Archive`/`7z` |
| Tempo detection accuracy on real Suno masters | Medium — algorithmic | Manual confirm prompt remains; TC-TM-01 unchanged |

---

## 8. Recommendations (not done in this change)

1. **Splitter boundary detection only fires on *rising* energy.** A chorus → quiet verse transition is not detected. A symmetric (absolute-difference) ODF would catch both; it changes behaviour, so it needs a listening test.
2. **Tempo mapping across multiple items** — the script assumes one item per song; a batch mode would need a per-item tempo-map pass.
3. **True-peak / LUFS**: consider delegating the ceiling to a limiter/JSFX and reporting measured LUFS via `reaper.GetTrackUIVolume`-style metering, or document the RMS target as the contract (already done).
4. **Add a real-REAPER smoke test** to CI-on-demand (manual workflow dispatch) once a headless REAPER runner exists.
5. **Consider `InsertTrackInProject`** instead of the superseded `InsertTrackAtIndex` when the minimum REAPER requirement rises to 7.0.

---

## 9. Reproducing this audit

```bash
# tests + static checks (no REAPER needed)
lua5.4 tests/run_tests.lua
python3 tools/run_lua.py            # fallback: embedded Lua via `pip install lupa`

# lint
python3 tools/lua_lint.py *.lua "Various/SGM_Suno ZIP Importer.lua" tests/*.lua

# syntax
for f in *.lua Various/*.lua; do luac5.4 -p "$f"; done
```

To see the original failures reproduced, check out the parent commit and run the suites — A1, A2, B1, B3, B4, B5, B6, B8 and B9 each fail at least one assertion.
