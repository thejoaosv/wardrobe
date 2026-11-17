<div align="center">

# Wardrobe

Your clothes, extracted and organized with gpt-image.

[![License: MIT](https://img.shields.io/badge/license-MIT-191919?style=flat-square)](LICENSE)
[![Node 22+](https://img.shields.io/badge/node-22%2B-191919?style=flat-square)](package.json)

[See the original post →](https://x.com/cdngdev/status/2076812846793650485)

</div>

![Wardrobe gallery](docs/screenshots/gallery.png)

![Modeled wardrobe editor](docs/screenshots/editor.png)

## Quick start

```bash
git clone https://github.com/tandpfun/wardrobe.git
cd wardrobe
npm install
cp .env.example .env
npm run dev
```

⚠️ The importer stays disabled until AI is set up. Either sign in to the [Codex CLI](https://github.com/openai/codex) with `codex login` to use your ChatGPT plan, or add `OPENAI_API_KEY` to `.env`. Optionally add a PNG photo of yourself at `data/model-reference.png` to try planned outfits on.

Open [localhost:5173](http://localhost:5173).

## iPhone app: Valet

`ios/` contains Valet, a native SwiftUI app named after the valet stand where you lay out tomorrow's clothes. It talks to the server above:

- **Plan**: generate outfits for 1–14 days, with one style for all days or a style per day, and the weather. Every outfit has a base top (t-shirt, shirt); cold days add a hoodie or sweater over it and a jacket on top. Swipe a day to restyle or delete it.
- **Closet**: tap a piece to mark it as in the laundry (unavailable) or available again. "Laundry done" returns everything at once.
- **Import**: take a photo or pick some from your camera roll, then review each crop and cutout. A piece can redo its cutout later from its photo or a new one.
- **Try on**: ask for a photo of yourself wearing a planned outfit (needs `data/model-reference.png`).
- **Notifications**: you're told when pieces are ready to review or a try-on is done, even with the app closed.

Planning remembers what you wore or planned on nearby dates. It won't reuse a piece within 4 days unless you have no alternative, it never repeats an outfit combination, and it skips anything in the laundry. Outfits that contain laundry items or nearby repeats are flagged.

```bash
open ios/Wardrobe.xcodeproj   # after editing ios/project.yml, regenerate with: cd ios && xcodegen
```

In the app's Settings, enter your Mac's address, for example `http://my-mac.local:5173` (the simulator can use `http://localhost:5173`). Plans live in `data/plans.json`.

## Import with Codex

This repo includes two Codex skills: one imports clothes and generates modeled item photos; the other styles complete outfits and generates a modeled lookbook.

```text
$import-clothes Import the clothes from ~/Pictures/outfits, create modeled photos, and add them to this wardrobe.
$generate-outfits Create modeled outfit ideas from my wardrobe.
```

Open the cloned repo in Codex and run either prompt. The import skill asks for a local model-reference PNG when needed, reviews every cutout and modeled photo, then writes to `data/library.json` and `data/imported/`. The outfit skill asks how many looks to create, then curates, generates, verifies, and saves the complete collection under `data/`.

### For agents

If you are setting up Wardrobe for a user, ask how they want to import their clothes:

- **Codex:** Ask for a folder or camera-roll location and a model-reference PNG, then extract, model, and import the individual pieces by following [the bundled import skill](.agents/skills/import-clothes/SKILL.md). Afterward, offer to create a requested number of modeled looks with [the outfit-generation skill](.agents/skills/generate-outfits/SKILL.md).
- **Web UI:** Help the user configure their own `OPENAI_API_KEY` and `data/model-reference.png`, then let them import through the app.

## What it does

- Runs on your ChatGPT plan through Codex, or on the OpenAI API with the newest available models
- Detects the garments a photo is meant to show, and leaves out background clutter
- Has a second AI pass review every result (detected pieces, cutouts, try-ons, outfit plans) and retries with its notes, so a cutout that turns "ROTATION" into "RUTGERS" or shows a person gets redone
- Extracts product cutouts with transparent backgrounds from the photo you picked
- Generates an optional modeled editorial preview
- Keeps originals, jobs, generated images, and the JSON database local in `data/`
- Supports drag, drop, paste, editing, review, regeneration, and approval

## Configuration

| Variable | Default |
| --- | --- |
| `WARDROBE_AI_PROVIDER` | `auto`: your ChatGPT plan through `codex login` if signed in, otherwise `OPENAI_API_KEY`. Set `codex` or `api` to force one. |
| `OPENAI_API_KEY` | Required only without Codex |
| `OPENAI_VISION_MODEL` | Newest `gpt-*-terra` (falls back to newest `gpt-*-mini`) |
| `OPENAI_PLANNER_MODEL` | Newest `gpt-*-terra` (falls back to newest `gpt-*-mini`) |
| `OPENAI_IMAGE_MODEL` | Newest `gpt-image-*` |
| `CODEX_MODEL` | Per task: terra to find clothes and plan, luna to drive image generation |
| `OPENAI_IMAGE_QUALITY` | `high` |
| `WARDROBE_MODEL_REFERENCE` | `data/model-reference.png` |
| `WARDROBE_DATA_DIR` | `data` |

## License

[MIT](LICENSE)
