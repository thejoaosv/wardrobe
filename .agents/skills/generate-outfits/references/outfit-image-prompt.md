# Outfit image prompt

This mirrors the app's own try-on prompt (`buildTryOnPrompt` in `scripts/import-job-api.mjs`): an edit of the user's photo, not a new photograph. Attach the user's photo first, then the optional head close-up, then the garment cutouts (or one numbered sheet) in the listed order. Delete optional clauses that do not apply, and renumber the images when the close-up is left out.

```text
Use case: identity-preserving clothing edit
Asset type: vertical outfit try-on photograph

Image 1: a photo of the user. This is the photo to edit.
[Image 2: a close-up of the same person's head from Image 1, the authority for their face, hair and glasses.]
The remaining images are product cutouts of the exact garments to put on them:
Image 3: exact base top ([NAME]).[ Its text reads: [TEXT].]
Image 4: exact bottom ([NAME]).
[Image 5: exact mid layer or outer layer ([NAME]).]
[Or, past five images in total: Image 3: a reference sheet with every garment, each numbered in its corner: 1. exact base top ([NAME]). 2. ...]

Edit Image 1: replace everything the person wears, including any shoes, watch, wristband and anything they hold, with exactly this outfit and nothing else: [base top: NAME; mid layer: NAME; outer layer: NAME; bottom: NAME; shoes: NAME]. Replace the background with [SIMPLE REAL-WORLD SETTING] that suits a [STYLE] outfit, simple and softly out of focus.

Keep the person exactly as they are in Image 1: the same face and features, hair color, length and style, glasses, skin, age, height and build, and the same pose, camera angle and full-body framing from head to shoes, facing the camera. This must be unmistakably the same real person, not a lookalike: do not beautify, slim, de-age or restyle their hair. [Plain understated shoes replace theirs because no shoe reference is provided.] Hands hang relaxed and empty.

[Layering: base top innermost, then the mid layer, then the outer layer. The base top shows naturally a little at the neckline or below the hem of the layer over it. Only open a layer if its reference has a real full front zipper or buttons; never invent a closure.]

Garment fidelity: each garment matches its cutout exactly: color, material, fit, construction, pattern, graphics, logos, proportions and closures, worn with natural drape and creases on this body. Text reads letter for letter as listed; never swap in a different or more familiar word or symbol.

Realism: one real camera photograph with natural light, true-to-life colors, natural skin texture and believable fabric; the lighting on the person matches the new scene.

Avoid: a different face or hairstyle, a new pose or back view, any of the original clothes, shoes or accessories from Image 1, hidden or redesigned garments, changed logos or text, extra layers, hats, bags or jewelry, cropped head or feet, extra people, text overlays, watermarks, a studio cutout look, or synthetic AI polish.
```

Use a corrective pass rather than repeating the same prompt when an output fails: append "A reviewer rejected the previous attempt. Fix every one of these:" followed by each concrete failure as a short instruction, as the app does.
