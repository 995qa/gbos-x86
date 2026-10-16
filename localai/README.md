# AI features through your own API (AICore stand-in)

Google's on-device AI (**AICore**, package `com.google.android.aicore`) is what Magic Pointer asks for its suggestions. On this
laptop Google's servers refuse AICore's setup request because it carries no hardware key attestation (see HANDOFF.md, 2026-10-16),
so the stock features cannot work. This folder builds a stand-in that answers the same requests by calling **an API you provide**:
any OpenAI-compatible chat service (a Gemini API key works through Google's OpenAI-compatible endpoint; OpenAI, OpenRouter, or a
model server on your own network work too). It does not pretend to be Google hardware and never contacts Google's attestation
services.

**Privacy:** the text and pictures you point at are sent to the provider whose address and key you enter. It is opt-in, asked on
every install and update, and answering *n* removes it together with the saved key.

An earlier version ran a local model (Gemma on the laptop's CPU). It was too slow on this CPU and is gone: the installer deletes its
files (model, vision file, llama-server) from the SSD on every install/update. The work is preserved on the `local-ai` branch.

## Setting it up

Boot the stick, choose **2** (install or update), then **1** (Update). The installer asks:

1. `Use an API for the AI features? [y/N]`
2. If you say yes, one of:
   * a settings file on the stick, `gbos/localai/api.conf` (prepare it on a computer; **delete it from the stick afterwards**), or
   * your saved settings (`Keep them? [Y/n]`), or
   * the prompts: API address (blank = `https://generativelanguage.googleapis.com/v1beta/openai`), model name, the **API key**
     (typed with the screen echo off; it is never written to the install log), and a cap on requests per hour (blank = 120).

`api.conf` is plain `KEY=VALUE` lines:

```
BASE_URL=https://generativelanguage.googleapis.com/v1beta/openai
MODEL=<the model name your provider uses>
API_KEY=<your key>
MAX_PER_HOUR=120
```

`http://` addresses are accepted only for a server on this machine or your own network (`localhost`, `192.168.x.x`, `10.x`, a one-word
host name). Never paste the key into a chat, an issue or git.

## How it plugs in

* **Installer** (`usb/install.sh`, `localai_step`): installs the app and scripts to `GBOSSYS:/gbos/localai/`, saves the settings to
  `/data/gbos-localai/api.conf` (root-only, mode 600), sets `LOCAL_AI=1` in the installed `gbos.cfg`. `LOCAL_AI=0|1` in the stick's
  `gbos.cfg` answers without asking.
* **hook.sh** (stage0): when `LOCAL_AI=1`, adds the `prep.sh` and diagnostics services to `gbos.rc`.
* **prep.sh** (post-fs-data, root, every boot): binds a read-only copy of `localai.apk` over the system AICore stub, copies
  `api.conf` into the AICore app's own private storage (readable by that app only), removes a Play-updated AICore and the stale
  package-manager cache entry, and (optionally) binds the patched Magic Pointer.
* **diag.sh**: writes `logs/boot-N/localai.txt` (package state, the settings with the **key never shown**, and our logcat lines).

Every inference is logged as `inference: ... provider <host> model <name>` and `inference done in N ms` (first 120 characters of the
reply); errors are mapped to AICore codes (401/403 wrong key, 429 quota or the hourly cap, 5xx provider trouble, no network).

## What gPointer asks for (protocol notes)

Worked out from gPointer's own client code, not from Google's service:

* It binds `com.google.android.aicore` / `com.google.android.apps.aicore.service.multiuser.AiCoreMultiUserService` (falling back to
  `…service.AiCoreService`) and needs the normal permission `com.google.android.apps.aicore.service.BIND_SERVICE`, which our manifest
  defines. The multi-user service returns an `IAiCoreServiceProvider`; `get(callback)` is answered with the `IAICoreService`.
* Setup: `getApiVersion` (needs >= 7), `getFeatureOrControl(713, 1)`, `getFeatureStatus` (3 = available), `getLLMLegionService`.
  Feature 713 is the "Legion server model" Magic Pointer uses.
* Inference: `runCancellableInferenceWithInfo(LLMRequest, callback)`, answered with an `LLMResult` holding one reply.
* The prompt is gPointer's `action_suggestions_prompt` (about 14,000 characters) as a system message, then one user message per selected
  area: its OCR text, or, for a picture, the bitmap itself (field 3 of `LLMMessage`, a `Bitmap` parcelable). The reply must be up to
  3 lines of `chip text<TAB>TOOL`; `Chips.java` repairs the format when a model drifts.
* Pictures are decoded, shrunk to at most 1024 px, JPEG-encoded and sent as `image_url` data URIs. Consecutive messages of one role
  are merged so roles alternate.
* Messages use Google's SafeParcel framing; `Wire.java` implements just the parts needed and skips unknown fields by size.
  **Position must be taken after the size int is read** (`Wire.endOf`): getting that wrong broke the first real request.

## Patched Magic Pointer (needed on this laptop)

With AICore answering, gPointer still closed itself: `RobinKit capability check failed ... Terminating immediately`. It asks the Gemini
app (RobinKit, a local service in `googlequicksearchbox`) for its capabilities and requires BOTH `TEXT_QUERY` and
`TEXT_QUERY_WITH_ATTACHMENTS`; the Gemini app here offers only the first. `patch_gpointer.py` changes one byte in `ErrorsKt.<clinit>`
(the required list becomes `[TEXT_QUERY, TEXT_QUERY]`), fixes the dex checksum/SHA-1 and zip CRCs, and leaves the file size and
Google's (now non-verifying) signature block alone. It refuses any APK but the exact build it was written for (sha256 pinned).
This worked: PackageManager accepted it and Magic Pointer reached its selection UI (boot 29).

* `build_gpointer.sh` extracts the app from your `lapis/parts/product_a.img` and writes `usb/localai/gpointer.apk` (235 MB, Google's
  binary: gitignored, never in the release image). Put it on the stick next to the other files.
* The installer copies it to `/data/gbos-localai/gpointer.apk` (read-only); `prep.sh` binds it over the system copy and removes the
  Play-updated Magic Pointer, which would otherwise win. Play may re-update while running; it is removed again on the next boot.

## Building and testing

```sh
localai/fetch_toolchain.sh     # Android build tools + platform jar (130 MB, sha1-verified) into localai/.toolchain
localai/build_apk.sh           # -> usb/localai/localai.apk (signing key in ~/.gbos-localai, never commit it)
localai/build_gpointer.sh      # -> usb/localai/gpointer.apk (needs lapis/parts/product_a.img)
localai/test.sh                # unit tests, docker only
```

`test.sh` runs: the chip-format repair; the parcel code against a reference reader written from gPointer's SafeParcel code (using a
stand-in `Parcel`); the API client (JSON, settings, request building incl. images and message merging, reply parsing, the hourly cap,
and a real HTTP round trip against a fake provider that checks the key travels only in the `Authorization` header and never in an
error); and the installer's AI step run under busybox with scripted answers (settings saved with mode 600, key never in the log,
leftovers deleted, bad input rejected, *no* removes everything). `test/VisionLive.java` is a manual check of the picture path against
any OpenAI-compatible server that has vision (it was run against Gemma 4 with its vision file: both a photo and a chart were read).

## Limits and honest unknowns

* **Not yet run on the laptop in this form.** Checked off-device: the API client including pictures, the installer step, the wire
  format. Not checkable off-device: `Bitmap` decoding inside Android (`LlmBinder.bitmapToDataUri`) and the live provider.
* gPointer logged `OcrTextRecog: NPU compilation failed`, so selections may arrive as pictures rather than text; that is why pictures
  matter. If a provider has no vision, picture selections will fail or give generic chips.
* Needs Wi-Fi, and each selection costs one request against your key (capped by `MAX_PER_HOUR`).
* Google's AICore updates change the interface; unknown fields are skipped and unknown calls refused, but a new required call would
  need adding to `CoreBinder`/`LlmBinder`. Only the language-model interface is implemented, not Gboard's rewrite/embedding services
  or notification summaries.
* The API key sits on the user's own SSD (`/data/gbos-localai/api.conf`, root-only, plus a copy private to the AI app). Anyone with
  the stick/SSD and tools can read it; use a key you can revoke.
