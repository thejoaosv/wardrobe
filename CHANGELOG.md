# Changelog

The server reports its version and this changelog at `/api/import/version`. Valet shows it in Settings, behind a few taps on the server version.

## 1.5.1 — 2026-11-18
- Text that appears on both the front and the back stays listed on both sides when a back photo updates a piece

## 1.5.0 — 2026-11-17
- Try-ons ignore the clothes in your photo, list the outfit layer by layer, match the scene to the weather, and get three tries
- Try-ons and cutouts that were running when the server restarted pick up where they left off
- Adding a back photo updates the piece's colors, description and the text on each side
- Plans can set a color palette, a piece to build around and a note per day

## 1.4.0 — 2026-11-17
- Photos are searched for clothes in the background and resume after a restart, so a phone losing Wi-Fi or going to sleep loses nothing
- Outfit styling runs in the background too
- Cutouts and try-ons wait in line, two at a time, and say how many are ahead
- Approving or discarding a piece twice, or retrying after a dropped connection, is safe
- Photos are capped at 2048px and the app gets small previews instead of full PNGs
- Idle connections stay open longer, which stops "The network connection was lost"

## 1.3.0 — 2026-11-17
- Wears before washing has a default per type of clothing, set in Settings
- Back photos are kept, and a back cutout can be redone from its photo without a new one
- Back cutouts pressed and straightened

## 1.2.0 — 2026-11-17
- Server versions, an API level the app checks, and this changelog
- AI checks setting: Thorough reviews and retries every result, Fast skips the reviewer
- Upload the photo of you for try-ons from the iPhone
- Clearer piece, plan, add-clothes and settings screens in Valet
- Existing cutouts pressed and straightened again

## 1.1.0 — 2026-11-17
- Hoodies and sweaters are a mid layer worn over a t-shirt or shirt; plans follow the weather you pick
- Pieces get specific names, a stylist description and an exact copy of their printed text
- A second AI pass reviews detections, cutouts, try-ons and plans, and retries with its notes
- Cutouts come out flat-laid, with wrinkles and folded sleeves smoothed away
- Garment skeletons and live status while the AI works
- Take photos in the app, and redo a piece's cutout from its photo or a new one

## 1.0.0 — 2026-11-16
- Valet, the iPhone app: plan outfits, manage laundry, import clothes and try outfits on
- Codex on your ChatGPT plan as the AI provider
