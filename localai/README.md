# Local AI replacement for AICore

Google's on-device AI service (**AICore**, package `com.google.android.aicore`) is what Magic Pointer asks for its
suggestions. On this laptop Google's servers refuse AICore's setup request because it carries no hardware key
attestation (see HANDOFF.md, 2026-10-16), so the stock features cannot work. This folder builds a stand-in that
answers the same requests with **Gemma 4 E2B running on the laptop's own CPU**. It never contacts Google and does
not pretend to be hardware it isn't.

It is **optional**: the installer asks on every install and every update ("Install or keep the local AI
replacement? [y/N]"). Answering n removes it again.

## What is in it

| Piece | Where | Role |
|---|---|---|
| `localai.apk` | built from `localai/src` | Package `com.google.android.aicore` with AICore's service class names. Speaks the binder protocol gPointer uses and forwards each request over loopback HTTP to the model server. About 20 KB. |
| `llama-server` | llama.cpp v0.7.0, built for Android x86_64 (AVX2/FMA, no AVX-512) | Runs the model. Started by init as `gbos_llama` after boot, listens on 127.0.0.1:8089 only. |
| `model.gguf` | `localai/fetch_model.sh` | Gemma 4 E2B QAT 4-bit, 3.35 GB, sha256 pinned. Never part of the release image. |
| `prep.sh`, `run.sh`, `diag.sh` | `usb/localai/` | Boot-time glue (below). |

## How it plugs in

1. **Installer** (`usb/install.sh`, `localai_step`): on *yes*, copies `localai.apk`, `llama-server` and the scripts to
   `GBOSSYS:/gbos/localai/` and the model to the ext4 data partition (`/data/gbos-localai/model.gguf`; there is not
   room for it next to `super.img`). It records `LOCAL_AI=1` in the installed `gbos.cfg`. `LOCAL_AI=0|1` in the stick's
   `gbos.cfg` answers without asking.
2. **hook.sh** (stage0, before Android starts), when `LOCAL_AI=1`: bind-mounts `localai.apk` over the system AICore stub
   under `/product/priv-app/AICorePrebuilt*/` and adds three init services to `gbos.rc`.
3. **prep.sh** (post-fs-data, root): removes a Play-updated copy of AICore from `/data/app` so the system package
   (ours) is the one PackageManager uses. The updated copy would otherwise win.
4. **run.sh** (`gbos_llama`, boot_completed): starts `llama-server` with the model.
5. **diag.sh** (`gbos_localaidiag`): writes `logs/boot-N/localai.txt` 60 s and 300 s after boot: package state,
   running services/processes, our logcat tags `gbos-localai` and `gbos-llama`, and gPointer's AICore lines.

## What gPointer asks for (protocol notes)

Worked out from gPointer's own client code, not from Google's service:

* It binds `com.google.android.aicore` / `com.google.android.apps.aicore.service.multiuser.AiCoreMultiUserService`
  (falling back to `…service.AiCoreService`) and needs the normal permission
  `com.google.android.apps.aicore.service.BIND_SERVICE`, which our manifest defines.
* The multi-user service returns an `IAiCoreServiceProvider`; `get(callback)` is answered with the `IAICoreService`.
* Setup: `getApiVersion` (needs >= 7 for the server-model path), `getFeatureOrControl(713, 1)`, `getFeatureStatus`
  (3 = available), `getLLMLegionService`. Feature 713 is "Legion server model", the one Magic Pointer uses.
* Inference: `runCancellableInferenceWithInfo(LLMRequest, callback)`, answered with an `LLMResult` holding one reply.
* The prompt is gPointer's `action_suggestions_prompt` (about 14,000 characters of instructions) plus the OCR text of
  the selected areas; it expects up to 3 lines of `chip text<TAB>TOOL` (TOOL is `NO_TOOL` unless an image/video/music
  tool is needed).
* Messages use the Google SafeParcel framing; `Wire.java` implements just the parts needed, and every unknown field
  is skipped by its size.

## Building

```sh
localai/fetch_toolchain.sh     # Android build tools, platform jar, NDK r27d: 790 MB, sha1-verified, into localai/.toolchain
localai/build_apk.sh           # -> usb/localai/localai.apk   (signing key kept in ~/.gbos-localai, never commit it)
localai/build_llama.sh         # -> usb/localai/llama-server  (clones llama.cpp v0.7.0 into localai/.llama.cpp)
localai/fetch_model.sh /Volumes/GBOS/gbos/localai   # the model, straight onto the stick
```

Everything builds in docker (`localai/Dockerfile`). The model is not in the repo or the release image: copy it to
`gbos/localai/model.gguf` on the stick (or run `fetch_model.sh` with the stick's folder) before choosing *yes*.

## Patched Magic Pointer (optional, needed on this laptop)

With AICore answering, gPointer still closed itself: `RobinKit capability check failed ... Terminating immediately` (boot 26).
It asks the Gemini app (RobinKit, a local service inside `googlequicksearchbox`) for its capabilities and requires BOTH
`TEXT_QUERY` and `TEXT_QUERY_WITH_ATTACHMENTS`; the Gemini app here offers only the first. `patch_gpointer.py` changes one byte
in `ErrorsKt.<clinit>` (the second list entry loads `TEXT_QUERY` instead of `...WITH_ATTACHMENTS`, so the required list is
`[TEXT_QUERY, TEXT_QUERY]`), recomputes the dex checksum/SHA-1 and the zip CRCs, and leaves the file size and Google's
(now non-verifying) signature block alone. It refuses any APK but the exact build it was written for (sha256 pinned).
Screenshots are therefore not attached to Gemini queries (the Gemini app doesn't offer attachments here).

* `localai/build_gpointer.sh` extracts the app from your `lapis/parts/product_a.img` and writes `usb/localai/gpointer.apk`
  (235 MB, Google's binary: gitignored and not in the release image). Put it on the stick next to `model.gguf`.
* The installer copies it to `/data/gbos-localai/gpointer.apk` (read-only). `prep.sh` binds it over
  `/product/priv-app/ContextualCursorPrebuilt/*.apk` if the size matches, removes the Play-updated Magic Pointer (which would
  override the system copy; it is a newer split APK, version 26091600) and its package-cache entry, every boot.
* **Unverified:** whether PackageManager accepts the APK with Google's signature no longer verifying (`diag.sh` prints the
  package state and any `INSTALL_PARSE`/`NO_CERTIFICATES` errors), and whether the Gemini app's first-party security policy still
  admits gPointer. Re-signing was avoided on purpose: RobinKit appears to check the caller's certificate.
* Play may re-update Magic Pointer while running; the update is removed again on the next boot.

## What has been tested (and what hasn't)

* **Model and prompt, in docker on an Apple-silicon Mac** (same llama.cpp tag, same flags as `run.sh`): gPointer's real
  14,198-character instruction prompt plus sample text gave correctly formatted chips (`Summarize the blockers<TAB>NO_TOOL`
  ...). Cold first request: 3,166 prompt tokens in 23 s. Later requests reused 3,112 cached tokens and took about 1 s. The
  i5-8365U will be several times slower on the first request; the cache still makes the rest fast.
* **Chip repair** (`Chips.java`): the model sometimes joins chips with spaces or leaves the last tool tag off; gPointer
  splits on newline then tab, so the service rewrites the reply. `localai/test.sh` runs the unit tests (docker).
* **Wire format**: checked line by line against the SafeParcel writer/reader in gPointer's own code.
* **Not tested:** the binder service against the real gPointer, and everything on the laptop. That needs a boot.

## Limits and honest unknowns

* **Text only.** gPointer may attach screenshots; they are ignored. Suggestions come from the OCR text it sends.
* **Slow.** First request: the long instruction prompt must be read (a minute or so on this CPU); the server's prompt
  cache makes later requests much faster. gPointer gives up after 240 s.
* **Quality** is a 2B-class model's; it may break the `chip<TAB>TOOL` format sometimes.
* **Untested on hardware at the time of writing.** The things to check in `logs/boot-N/localai.txt` after the first boot:
  that `pm path com.google.android.aicore` points at our APK (not a `/data/app` path), that our logcat lines appear when
  Magic Pointer is used, and that `llama-server` stays up. If a Play-updated AICore still wins, `prep.sh` is the place
  to fix it.
* Google's AICore updates change the interface; the code skips unknown fields and refuses unknown calls, but a new
  required call would need adding to `CoreBinder`/`LlmBinder`.
* The stock AICore is replaced for **all** features that use it, not just Magic Pointer (smart summaries, etc. will
  hit "not supported" or get the same local model).
