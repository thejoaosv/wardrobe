---
name: generate-outfits
description: Curate complete outfits from the local Wardrobe database and generate identity-preserving vertical try-on photos for every selected look end to end, as an offline lookbook outside the app. Use when a user asks Codex for outfit ideas, combinations, looks, styling suggestions, a lookbook, or modeled outfit images based on clothes already imported into this Wardrobe.
---

# Generate Outfits

Create a complete local outfit collection from `data/library.json`: select strong combinations, generate a vertical try-on photo for each, verify every result, and save the finished manifest and images under `data/`.

## How this relates to the app

The app plans and dresses outfits itself: the Plan screen saves outfits per day in `data/plans.json`, and its try-on edits the user's own photo (`POST /api/import/plans/DATE/try-on`). This skill makes a separate lookbook. The app does not read `data/outfits.json` and does not list these outfits; only the image files are reachable, at `/api/import/outfits/FILE`. To have the app style a day, use the app instead of this skill.

## Begin with the count

Ask `How many outfits would you like me to generate?` unless the user already provided a positive count. Do not choose a default silently.

Also obtain the intended season, occasions, dress codes, or styling direction when the user named them. Otherwise create a balanced everyday mix without blocking on more questions.

Do the workflow end to end after receiving the count. Do not stop after returning suggestions, a manifest, or prompts.

## Requirements

- Read and follow the built-in `imagegen` skill before generating images.
- Require `data/library.json`, enough tops and bottoms for the requested count, and a local identity reference at `data/model-reference.png` or `WARDROBE_MODEL_REFERENCE`.
- Keep every source garment and identity image local and unchanged.
- Never add `data/`, the identity reference, garment images, or generated photos to Git.
- Use only wardrobe items that exist in the current database and whose local assets resolve successfully.
- Generate exactly the requested number of unique outfits and exactly one accepted modeled photo for each.

## Parallel work

Use subagents when the user requests more than eight outfits or explicitly asks for parallel generation. Keep one main agent responsible for the complete wardrobe inventory, global combination uniqueness, garment-usage balance, manifest reconciliation, and final QA.

Assign each worker a disjoint set of outfit IDs plus the exact identity and garment reference paths. Require every worker to return the outfit ID, filled prompt, reference list, generated path, status, and visual-review notes. Never allow two workers to generate or write the same outfit ID. Run workers in waves when concurrency is limited, reconcile results after every wave, and resume only missing or failed IDs.

## 1. Inspect the wardrobe

Read `data/library.json`. Resolve `/api/import/library/FILENAME` assets to `data/imported/FILENAME`. Group items by:

- `upperbody` — base tops: t-shirts, shirts, polos, tank tops (every outfit needs one)
- `midlayer` — hoodies, sweatshirts, sweaters, cardigans and fleeces worn over the base top
- `wholebody_up` — jackets, coats and other outer layers
- `lowerbody` — bottoms
- `accessories_up` — optional accessories
- `shoes` — optional shoes

Create checkerboard contact sheets of at most 12 garment cutouts and inspect them. Use both metadata and visual evidence; do not style from filenames or colors alone.

If the wardrobe cannot support the requested number of genuinely distinct outfits, tell the user the maximum useful count and ask whether to continue with that number.

## 2. Curate the combinations

Each outfit has exactly one `upperbody` base top and one `lowerbody` bottom, plus an optional `midlayer` over the base top, an optional `wholebody_up` outer layer, optional shoes, and at most one accessory, the same structure the app's planner uses. A midlayer or outer layer never replaces the base top. Pieces marked `"unavailable": true` are in the wash; leave them out. Use these principles:

- Favor tonal or analogous color harmony for cohesion.
- Use complementary contrast selectively and keep one color or garment dominant.
- Let one graphic, pattern, texture, or saturated piece carry the statement.
- Balance visual weight and silhouette: pair fuller bottoms with a cleaner top; keep heavier layers over a simple base.
- Use outer layers to frame the base look, repeat a present color, or add one controlled contrast.
- Keep layered looks physically plausible and make every selected garment visibly identifiable.
- Diversify garment usage instead of repeatedly leaning on the easiest neutral pieces.

Cover a useful mix of the user’s requested contexts. Without specific direction, balance casual, smart-casual, warm-weather, layered, dark-tonal, and statement looks as the wardrobe permits.

Build `$WORK/outfits.json` with the final target count:

```json
{
  "version": 1,
  "outfits": [
    {
      "id": "navy-camel-classic",
      "name": "Navy & Camel Classic",
      "occasion": ["smart-casual", "office"],
      "garmentIds": ["import-...", "import-..."],
      "reason": "Deep navy and camel create controlled warm-cool contrast.",
      "setting": "a quiet warm-stone courtyard with restrained greenery",
      "image": "outfit-images/navy-camel-classic-1794955186239.png",
      "status": "planned"
    }
  ]
}
```

Use stable lowercase hyphenated IDs. Reject duplicate garment combinations even when names or settings differ.

## 3. Prepare references and prompts

Create one generation package per outfit, in this order:

1. The user's photo (identity reference; this is the photo that gets edited)
2. Optional close-up of the user's head cropped from it, when the face is small in the photo
3. Each selected garment's front cutout (`image`), base top first, then midlayer, outer layer, bottom, shoes, accessory

Codex's image tool takes at most five input images. When the package would exceed that, put the garment cutouts on one numbered reference sheet instead of separate images.

Read [references/outfit-image-prompt.md](references/outfit-image-prompt.md) and fill its template from the exact outfit record. Inspect every midlayer and outer-layer reference before choosing the layered clause; never infer a zipper, buttons, placket, opening, or closure.

Rotate simple, softly out-of-focus real-world settings that suit each outfit across the collection.

## 4. Generate every outfit

Create one vertical 2:3 (1024x1536) try-on PNG per outfit with Imagegen, editing the user's photo. Save working outputs outside `data/` until they pass review. Use the smallest valid set of references for each call and never omit a selected garment.

Generate in bounded batches when the collection is large. Track every outfit as `planned`, `generated`, `accepted`, or `failed`; resume only missing or failed IDs.

## 5. Verify and correct

Compare every output against the identity and all garment references. Inspect contact sheets of at most 12 modeled outfits, then open questionable images individually.

Require:

- recognizable identity, face, hair, age, build, and body proportions
- every selected garment present and recognizable
- exact garment color, material, fit, construction, graphics, logos, text, proportions, and closures
- the user's own pose, camera angle and complete head-to-shoes framing, with realistic anatomy
- natural layering without invented openings or hidden inner pieces
- no unselected visible garments except plain neutral shoes or invisible basics when no shoes were selected
- no extra person, text overlay, watermark, product mockup, or synthetic AI polish

Regenerate identity drift, missing or redesigned garments, fake closures or text, anatomy failures, or cropped feet. Do not mark an outfit accepted based on plausibility alone.

## 6. Deliver locally

After all requested outfits pass:

1. Create `data/outfit-images/` if needed.
2. Copy each accepted PNG to `data/outfit-images/OUTFIT-ID-TIMESTAMP.png`, with a new timestamp for every regenerated image. The app serves this folder with a one-year immutable cache, so reusing a file name would keep showing the old image.
3. Set every accepted manifest image to `/api/import/outfits/OUTFIT-ID-TIMESTAMP.png`.
4. Atomically write the exact requested collection to `data/outfits.json`.
5. Reopen every copied file and verify that the count of images, unique outfit IDs, and accepted manifest records all equal the number the user requested.

Never write to `data/plans.json` or name files after dates (`YYYY-MM-DD-*.png`): those belong to the app's planner and its try-ons. The app does not display this collection; the local images and manifest are the deliverable.

## Finish

Report the requested and completed count, output paths, any regenerated failures, and the styling mix. Display up to 12 modeled outfits in chat and point the user to the local folder for the rest.
