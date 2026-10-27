# FLAC → MP3 inside foobar2000

Build, install, settings and usage are in [README.md](README.md). This file records why the component exists
and how it behaves.

## Options considered

Context: foobar2000 2.x x64 with its built-in Converter (`foo_converter`). Option 2 needs a scripting component
such as JScript Panel 3. Option 3 needs Visual Studio 2022 with C++ to build.

### 1. foobar's own Converter — zero code
Right-click → Convert → LAME preset (320 / V0 / V1 / V2) with:
- Output folder: *Source track folder*
- Name format: `%filename%`
- If file already exists: *Overwrite*
- *Transfer metadata* on

Tags are written by foobar's own writer, so they match foobar's mapping exactly.
**Gaps:** it doesn't delete the source FLACs, and it doesn't replace FLAC→MP3 in playlists.
"Show output tracks when done" only makes a separate playlist.

### 2. Launch the external tool from foobar — small effort
A JScript Panel 3 button or context menu passes the selected paths to the standalone converter
(`FlacToMp3.ps1`, or a Go TUI). The same script can then replace items in foobar's own playlists
through the `plman` API. **Weak spot:** it has to wait for the external process to finish first.

### 3. Native foobar2000 component (C++, foobar2000 SDK) — chosen
Right-click → **Convert to MP3 ▸ CBR 320 / V0 / V1 / V2**:
- decodes with foobar's own decoders and encodes with `lame.exe`
- writes tags and cover art with **foobar's own tag writer**, so the result matches foobar exactly
- replaces FLAC→MP3 in **every foobar playlist**, in the same position (undo with Ctrl+Z)
- moves source FLACs to the Recycle Bin (optional)
- rewrites `.m3u` / `.m3u8` files under a chosen main folder (optional, with an optional `.bak` copy)
- shows foobar's progress dialog with Cancel, and converts several files at once
- has its own settings page: *Preferences > Tools > FLAC to MP3*

**Risks:** a component runs inside foobar, so a crash takes foobar down. It was tested against a
separate portable foobar copy, not a real profile. A future major SDK change may need a rebuild.

### Comparison

| | Converter (1) | JScript + tool (2) | Component (3) |
|---|---|---|---|
| Tags identical to foobar | yes | close (own mapping) | yes |
| Delete source | no | yes | yes |
| foobar playlists updated | no | yes | yes |
| `.m3u8` files updated | no | yes | yes |
| Effort | none | small | largest |

## How a track is converted
1. foobar2000's own decoder writes the audio to a temp WAV in `%TEMP%` (16-bit, or 24-bit for hi-res sources).
   Sources with more than 2 channels are rejected, because LAME only encodes mono/stereo.
2. `lame.exe -S --noreplaygain <-b 320 | -V n>` encodes it to a temp MP3, which gets the LAME/Xing header for correct seeking.
   The process runs hidden, below normal priority, and is terminated on Cancel.
3. foobar2000's MP3 tag writer copies every tag plus ReplayGain (`input_info_writer`). Embedded pictures are then
   copied through `album_art_editor`.
4. The file is copied next to the FLAC as `song.mp3.tmp`, then renamed over `song.mp3`.
   Its modified time is set to the FLAC's.
5. Optional: the FLAC goes to the Recycle Bin (`SHFileOperation` with `FOF_ALLOWUNDO`).
6. After all tracks are done:
   - `.m3u`/`.m3u8` files under the main folder are rewritten. Dot-folders are skipped, and BOM, encoding, line endings
     and relative/absolute entry forms are kept.
   - Then, on the main thread, foobar playlists get `playlist_replace_item` with an undo backup per playlist.
   - Playlists are updated even after Cancel, so already-recycled FLACs don't leave dangling entries.

## Tag behaviour (identical to foobar2000's built-in Converter)
- MP3s get **ID3v2.3 (UTF-16)** by default. Multi-value fields are joined (`Artist A / Artist B`, `Pop;Rock`),
  DATE → `TYER`, and non-standard fields (LABEL, LYRICS, MUSICBRAINZ_*, custom ones) → `TXXX`.
  To get ID3v2.4 with separate values, change foobar2000's MP3 tag-writing options (*Preferences > Advanced > Tagging*).
- Pictures are copied **by type**: front, back, disc, icon and artist. Picture descriptions and other picture types aren't
  carried over, because foobar2000's art API only knows those five types.

## Testing that was done
Tests ran against a **portable copy** of foobar2000 2.25 in a temp folder, never the real profile, using the
test build described in the README:
- **Input:** FLACs including one heavily tagged with Unicode, multi-value fields, totals, MusicBrainz IDs,
  custom fields, lyrics and two pictures; one real library track; and one 24-bit track. Plus a playlist with a
  BOM and CRLF line endings, and a copy of it inside a dot-folder.
- **V0 with delete:**
  - Files converted and the FLACs went to the Recycle Bin.
  - foobar's "Default Playlist" was updated to the MP3s.
  - `list.m3u8` was updated with BOM and CRLF kept; the dot-folder copy was untouched.
  - All tags and both pictures were present, the Xing header was there, and no temp files were left.
- **V2 with delete, `.bak` option off:** the same, and no `.bak` was written.
- **Release build, CBR 320, default settings:** converted with the FLAC kept and no confirmation; all 44 fields and the cover were present.
- **Preferences page:**
  - Appears under *Tools* and follows foobar's dark mode.
  - The playlist options are greyed out while *Delete* is off.
  - *Settings...* in the context menu opens it.
