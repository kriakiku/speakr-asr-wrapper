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

Quickest manual way:

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

For running this as a real persistent service instead, see
[Running persistently](#running-persistently-launchd) below — that's the
intended way to run it day to day.

## Wiring into Speakr

```
ASR_BASE_URL=http://<this-machine-lan-ip>:9099
```

That's the only variable `asr_endpoint.py` strictly requires
(`base_url`) — diarization defaults on unless Speakr's own `diarize`
setting/request says otherwise.

## Running persistently (launchd)

`Scripts/manage.sh` builds, (re)installs, updates, and manages this as a
per-user launchd agent — no manual plist editing needed, it fills in the
checkout path itself.

```sh
./Scripts/manage.sh install     # build + load as a launchd agent (RunAtLoad + KeepAlive)
./Scripts/manage.sh status      # launchd state + a live GET /health check
./Scripts/manage.sh update      # git pull, rebuild, hot-swap the running service
./Scripts/manage.sh restart
./Scripts/manage.sh stop
./Scripts/manage.sh start
./Scripts/manage.sh logs        # tails logs/service.log + .err.log
./Scripts/manage.sh uninstall   # bootout + remove the plist (leaves the binary/logs)
```

Logs land in `logs/service.log` / `logs/service.err.log` inside the checkout
(gitignored). `KeepAlive` restarts the process if it crashes; none of this
survives the Mac being asleep or powered off — Speakr's ASR calls will just
fail until the Mac is back up. To pick up new commits automatically, put
`./Scripts/manage.sh update` on a periodic `launchd`/cron schedule of your
own — it's a safe no-op when there's nothing new.

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
