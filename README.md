# speakr-asr-wrapper

A small Swift/Vapor HTTP server that speaks the exact contract
[Speakr](https://github.com/murtaza-nasir/speakr)'s `asr_endpoint` connector
expects (`src/services/transcription/connectors/asr_endpoint.py`), backed by
[FluidAudio](https://github.com/FluidInference/FluidAudio) — Parakeet TDT v3
for transcription and the offline pyannote-Community-1 CoreML pipeline for
speaker diarization, both running on the Apple Neural Engine (not the
GPU/MPS), so this can run alongside a GPU-resident chat model (e.g. Ollama)
without contention.

Nothing here needs a Hugging Face account or token — FluidAudio's models
(`FluidInference/*`) are public, non-gated CoreML conversions.

## Why this exists

Speakr only supports speaker diarization through its `ASR_BASE_URL`
connector (whisper-asr-webservice/WhisperX-compatible). OpenAI-shaped
connectors (`openai_whisper`, `openai_transcribe`) don't carry a diarization
capability. FluidAudio has no ready-made HTTP server with that contract, so
this wraps `AsrManager` (transcription) + `OfflineDiarizerManager`
(diarization) and merges their output by timestamp into the JSON shape
Speakr parses.

## Endpoint contract

```
POST /asr?encode=true&task=transcribe&output=json&diarize=<bool>&enable_diarization=<bool>
     multipart field: audio_file

-> {"text": "...", "language": null, "segments": [{"start": 0.0, "end": 3.2, "speaker": "S1", "text": "..."}]}

GET /health, GET /        -> 200 "ok"
GET /v1/models             -> {"data": [{"id": "parakeet-tdt-0.6b-v3", "owned_by": "fluidaudio"}]}
```

`min_speakers`/`max_speakers` (sent by Speakr when set) are accepted but not
enforced — the offline pipeline's VBx clustering is threshold-based, not
fixed-K. `language`/`initial_prompt`/`hotwords`/`model` are accepted and
ignored (Parakeet auto-detects language; there's only one loaded model).

## Build & run

```sh
swift build -c release
PORT=9099 .build/release/SpeakrASRWrapper
```

First run downloads and compiles the CoreML model bundles (a few hundred MB);
they're cached locally afterwards. Env vars:

- `HOST` (default `0.0.0.0` — must stay on a LAN-reachable interface if
  Speakr runs elsewhere, e.g. in a Kubernetes cluster)
- `PORT` (default `9099`)
- `PARAKEET_VERSION` — `v3` (default, 25 European languages) or `ultra`
  (FluidAudio's own recommended successor to v3: same speed and languages,
  better accuracy — consider switching)

## Wiring into Speakr

```
ASR_BASE_URL=http://<this-machine-lan-ip>:9099
```

That's the only variable `asr_endpoint.py` strictly requires
(`base_url`) — diarization defaults on unless Speakr's own `diarize`
setting/request says otherwise.

## Running persistently (launchd)

```sh
swift build -c release
cp Scripts/com.kriakiku.speakr-asr-wrapper.plist ~/Library/LaunchAgents/
# edit the ProgramArguments path inside if your checkout isn't at
# ~/Developer/speakr-asr-wrapper
launchctl load ~/Library/LaunchAgents/com.kriakiku.speakr-asr-wrapper.plist
```

Logs land in `/tmp/speakr-asr-wrapper.log` / `.err.log`. `KeepAlive` restarts
it if it crashes; it does *not* survive the Mac being asleep or powered off —
Speakr's ASR calls will just fail until the Mac is back up.

## Known limitations (tested with synthetic TTS audio, not real recordings)

- Diarization needs real separation between speakers to cluster correctly —
  very short (<5s) turns or near-identical voices may get merged into one
  speaker. Tested and confirmed working with ~8-16s turns and a short gap
  between speakers.
- Transcription quality on Apple's own synthetic `say` voices was noticeably
  worse than expected (garbled words) for the robotic default voice, much
  better for the more natural one — Parakeet is trained on real human
  speech, so this is not representative of real recordings. Validate against
  an actual recording before relying on this for anything important.
- No chunking for very long files — `AsrManager` includes its own disk-backed
  processing for large files, but very long meetings are untested here.
