---
name: meeting-notes
description: Use when the user gives a meeting transcript, recording or rough notes and wants clean notes: "summarize this call", "action items from the meeting", "transcribe this recording".
---

# Meeting Notes

## When to use

- A transcript (txt, vtt, srt, docx, pasted text) or rough notes to turn into structured notes.
- An audio or video recording to transcribe first, then summarize.
- Pulling only action items or decisions out of a long call.
- Not for writing the follow-up email: do the notes here, then use `email-drafting`.
- Not for a status report across many meetings: use `internal-comms`.

## Steps

1. Get the text.
   - Text files: read directly. Strip timestamps from .vtt/.srt with `sed -E '/-->/d;/^[0-9]+$/d;/^WEBVTT/d;/^$/d' in.vtt > tmp/transcript.txt`.
   - Word or PDF: `textutil -convert txt -stdout in.docx`, `pdftotext -layout in.pdf -`.
   - Audio or video: convert, then transcribe with Whisper (see Tools). Save the full transcript to `output/<date>-<topic>/transcript.txt`.
2. Find the basics: date, title, who attended (from speaker labels or names mentioned), length.
3. Read the whole transcript before writing. Mark every decision, commitment, open question and number.
4. Write `output/<date>-<topic>/notes.md` with this structure:

```markdown
# <Meeting title> - <YYYY-MM-DD>
Attendees: ...

## Summary
2 to 4 sentences: why the meeting happened and what came out of it.

## Decisions
- <decision>, (who decided, if clear)

## Action items
| Owner | Task | Due |
|-------|------|-----|
| Maya  | Send revised quote to client | 2026-10-29 |

## Open questions
- <question> (who should answer it)

## Discussion
Short bullets by topic, only what someone would need later.
```

5. Owners and dates: use only what was said. If no owner was named write `Unassigned`; if no date write `No date`. Turn relative dates ("next Friday") into real dates using the meeting date and note it.
6. Optionally export: `pandoc notes.md -o notes.docx` if the user wants Word.

## Tools on a Mac

- Convert audio to 16 kHz WAV (built in): `afconvert -f WAVE -d LEI16@16000 -c 1 in.m4a tmp/audio.wav`.
- Video or odd formats: `brew install ffmpeg`, then `ffmpeg -i in.mp4 -ar 16000 -ac 1 tmp/audio.wav`.
- Whisper, local and private:
  - `brew install whisper-cpp`, download a model once, for example `curl -L -o tmp/ggml-base.en.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin`, then `whisper-cli -m tmp/ggml-base.en.bin -f tmp/audio.wav -otxt -of tmp/transcript`.
  - Or `python3 -m pip install --user openai-whisper` then `whisper tmp/audio.wav --model base --language en --output_format txt --output_dir tmp`.
  - Use `small` or `medium` models for accents or poor audio; `base` is fine for clear calls.
- Duration: `afinfo in.m4a | grep duration` or `mdls -name kMDItemDurationSeconds in.m4a`.
- Search a long transcript: `rg -n -i "action|follow up|by friday|decide|agreed" tmp/transcript.txt`.
- Copy the action items to the clipboard if asked: `pbcopy < tmp/actions.md`.

## Quality checklist

- Every action item has an owner (or `Unassigned`) and a due date (or `No date`).
- Decisions are things actually agreed, not ideas floated.
- Names spelled as in the transcript or attendee list; no invented attendees.
- Numbers, dates and amounts match the transcript exactly.
- Summary readable in 20 seconds.
- Transcript saved next to the notes when you made it.

## Reply to the user

One to three sentences: the headline outcome, how many action items, the path. For example: "The team agreed to launch on Nov 12; there are 5 action items, two for you. Notes are in output/2026-10-22-launch-sync/notes.md."

## Pitfalls

- Whisper invents words in silence and music; skim the transcript for repeated or nonsense lines and drop them.
- Speaker labels from Whisper do not exist; do not guess who said what unless the transcript has names.
- Treating "we should maybe" as a decision. Put it under open questions.
- Assigning tasks to the user that someone else volunteered for.
- Long recordings take time: whisper `base` runs roughly real-time-to-faster on Apple silicon; tell the user if a 2-hour file will take a while.
- Recordings and transcripts are private; never upload them to a web service.

Based on: written for Dottie
