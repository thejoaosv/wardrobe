import sharp from "sharp";

// Runs make(feedback) until check(result) finds no problems, at most `attempts` times. A thrown attempt counts as a problem.
// Returns the last result that was produced, with whatever problems it still has, so the user can judge it.
export async function untilApproved({ attempts, make, check, onRetry = () => {} }) {
  let feedback = [];
  let kept = null;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const result = await make(feedback, attempt);
      kept = { result, problems: await check(result) };
      if (!kept.problems.length) return kept;
      feedback = kept.problems;
    } catch (error) {
      // The work is no longer wanted (e.g. its job was discarded); another attempt would only spend AI usage.
      if (error.cancelled || (attempt === attempts && !kept)) throw error;
      feedback = [error.message];
    }
    if (attempt < attempts) onRetry(feedback, attempt + 1);
  }
  return kept;
}

export const withFeedback = (prompt, problems) => (problems.length
  ? `${prompt}\n\nA reviewer rejected the previous attempt. Fix every one of these:\n${problems.map((problem) => `- ${problem}`).join("\n")}`
  : prompt);

// Words quoted in a piece's text field, e.g. 'front: large "ROTATION", small "LX"' gives ["ROTATION", "LX"].
export function quotedWords(text = "") {
  return [...text.matchAll(/"([^"]+)"/g)].map((match) => match[1].trim()).filter(Boolean);
}

const letters = (value) => value.toUpperCase().replace(/[^\p{L}\p{N}]/gu, "");

// Quoted words the reviewer could not read in the generated image.
export function missingWords(expected, transcribed) {
  const seen = letters(transcribed);
  return quotedWords(expected).filter((word) => letters(word) && !seen.includes(letters(word)));
}

// Reviews are smaller than the originals, and transparent cutouts go on a light backdrop so the reviewer sees the edges.
const preview = (bytes) => sharp(bytes).rotate().resize(1024, 1024, { fit: "inside", withoutEnlargement: true }).flatten({ background: "#e8e8e8" }).png().toBuffer();

// A failed review call must not block the user's result; it is treated as unverified.
async function review(ai, request) {
  try {
    return await ai.json({ ...request, kind: "vision" });
  } catch (error) {
    console.warn(`AI review skipped: ${error.message}`);
    return null;
  }
}

const VERDICT = {
  type: "object",
  additionalProperties: false,
  properties: { pass: { type: "boolean" }, sourceText: { type: "string" }, outputText: { type: "string" }, problems: { type: "array", items: { type: "string" } } },
  required: ["pass", "sourceText", "outputText", "problems"],
};

const problemsOf = (verdict, expectedText) => {
  if (!verdict) return [];
  const problems = verdict.pass ? [] : verdict.problems.length ? verdict.problems : ["The result does not match the original"];
  const missing = missingWords(expectedText, verdict.outputText);
  if (missing.length) problems.push(`The text must read exactly ${missing.map((word) => `"${word}"`).join(" and ")}; the result reads "${verdict.outputText || "nothing"}"`);
  return problems.map((problem) => String(problem).slice(0, 240)).slice(0, 5);
};

// Checks a generated cutout against the user's photo. Returns problems phrased as instructions for the next attempt.
// referenceIsCutout: Image 1 is an older cutout that may itself be wrong, so the expected text wins over it.
export async function reviewCutout(ai, { photo, cutout, metadata = {}, side = "front", referenceIsCutout = false }) {
  const verdict = await review(ai, {
    images: [await preview(photo), await preview(cutout)],
    schema: VERDICT,
    prompt: `You are a strict quality reviewer for a wardrobe app.
Image 1 is the user's photo of a real garment (${side} view). Image 2 is a generated product cutout that must reproduce exactly that garment, shown on a plain light-grey backdrop.
Expected piece: ${metadata.name || "garment"} (${metadata.part || "clothing"}).${metadata.text ? ` Its text: ${metadata.text}.` : ""}${referenceIsCutout ? "\nImage 1 is an older generated cutout that may have wrong text or details. Where it disagrees with the expected text above, the expected text is correct and Image 2 must follow it." : ""}

Fail Image 2 if any of these is true:
1. It is not a product cutout of one empty garment: a person, face, skin, hands, mannequin, hanger, another garment, a room or a scene is visible.
2. It is a different garment: other type, silhouette, color, material, pattern, pockets, closures or proportions.
3. Any text, logo or graphic differs from Image 1. Transcribe all text in Image 1 into sourceText and in Image 2 into outputText, letter by letter. A different word, a missing word or a changed letter is a failure, however similar it looks.
4. The garment is cropped, incomplete or has a messy, broken outline.
5. The garment is not laid out straight: it is twisted, folded over, heavily wrinkled, or a sleeve or hem is tucked or bunched.

Ignore small differences in lighting, creases or wear that are part of the real garment's look, and size, care or inside-neck labels.
pass is true only when none apply. problems lists each failure as a short instruction for the next attempt, e.g. "The large chest text must read ROTATION, not RUTGERS" or "Lay the left sleeve flat instead of folded".`,
  });
  return problemsOf(verdict, metadata.text);
}

// Checks a photo of the user wearing garments: same person, every garment present and faithful, nothing extra.
export async function reviewWorn(ai, { person, image, garments }) {
  const references = garments.map((garment, index) => `Image ${index + 3}: ${garment.name}${garment.text ? `, text: ${garment.text}` : ""}`).join("\n");
  const verdict = await review(ai, {
    images: [await preview(person), await preview(image), ...await Promise.all(garments.map((garment) => preview(garment.image)))],
    schema: VERDICT,
    prompt: `You are a strict quality reviewer for a wardrobe app.
Image 1 is the user. Image 2 is a generated photo that must show this same person wearing exactly the garments in the reference images:
${references}

Fail Image 2 if any of these is true:
1. The person is not recognizably the same as Image 1 (face, hair, build), or there is more than one person.
2. A referenced garment is missing, hidden, or changed in type, color, pattern or fit.
3. Prominent text or graphics differ from their reference: chest graphics, slogans and large logos, the things readable in a full-length photo. Transcribe that text from the references into sourceText and from Image 2 into outputText; a changed word is a failure. Ignore small logos, patches and labels that can't be read at this scale.
4. An unreferenced visible garment, hat, bag or accessory was added (plain shoes are fine when no shoes are referenced).
5. The body is cropped, distorted, or has broken anatomy such as extra fingers or limbs.

pass is true only when none apply. problems lists each failure as a short instruction for the next attempt.`,
  });
  // No letter-by-letter check here: small text on a full-length photo isn't readable, so the reviewer judges what is.
  return problemsOf(verdict, "");
}

const DETECTION = {
  type: "object",
  additionalProperties: false,
  properties: {
    items: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        properties: { index: { type: "integer" }, keep: { type: "boolean" }, problem: { type: "string" } },
        required: ["index", "keep", "problem"],
      },
    },
  },
  required: ["items"],
};

// Judges each detected piece: is it something the user is showing to add, and are its crop and labels right?
// Returns which pieces to keep and the problems worth a second detection pass.
export async function reviewDetection(ai, { photo, found }) {
  const list = found.map(({ metadata }, index) => `Image ${index + 2} (index ${index}): ${metadata.name}, category ${metadata.part}${metadata.text ? `, text ${metadata.text}` : ""}`).join("\n");
  const verdict = await review(ai, {
    images: [await preview(photo), ...await Promise.all(found.map(({ crop }) => preview(crop)))],
    schema: DETECTION,
    prompt: `You are reviewing a clothing detector for a wardrobe app.
Image 1 is the photo the user uploaded to add their clothes. The detector cropped these pieces from it:
${list}

For every index decide:
- keep: true only if it is a real wearable garment, shoe or accessory the photo is clearly meant to show, worn by the main person or laid out or held as the subject. false for background items, other people's clothing, things on hangers, chairs or floors behind the subject, items mostly out of frame or hidden under other layers, small accessories (glasses, watches, wristbands, jewelry, bags) that are just worn with an outfit rather than the clear focus of the photo, duplicates of another index, and non-clothing.
- problem: for kept pieces, a short fix when the crop misses part of the item or mostly shows something else, the category is wrong (upperbody = t-shirts and shirts, midlayer = hoodies, sweaters and fleeces, wholebody_up = jackets and coats), or the name or text is wrong. For dropped pieces, why it was dropped. Empty when all is right.`,
  });
  if (!verdict) return { keep: found.map(() => true), problems: [] };
  const byIndex = new Map(verdict.items.map((item) => [item.index, item]));
  const keep = found.map((_, index) => byIndex.get(index)?.keep !== false);
  const fixes = found.flatMap(({ metadata }, index) => (keep[index] && byIndex.get(index)?.problem ? [`${metadata.name}: ${byIndex.get(index).problem}`] : []));
  const dropped = found.flatMap(({ metadata }, index) => (keep[index] ? [] : [`Leave out ${metadata.name}: ${byIndex.get(index)?.problem || "not something the user is adding"}`]));
  // Dropping pieces needs no second pass; only fixes do, and then the second pass should leave the dropped ones out too.
  return { keep, problems: fixes.length ? [...fixes, ...dropped] : [] };
}
