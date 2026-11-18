const DAY = 24 * 60 * 60 * 1000;
export const DATE = /^\d{4}-\d{2}-\d{2}$/;
// Garments worn within this many days of a target date count as "recent".
export const SPACING_DAYS = 4;
export const WEATHERS = new Set(["auto", "warm", "mild", "cold", "rain"]);
export const PALETTES = new Set(["any", "neutral", "muted", "bold", "monochrome"]);

// How many times a piece is usually worn before it needs washing, when the user hasn't set it.
export const DEFAULT_WEARS = { upperbody: 1, midlayer: 3, lowerbody: 3, wholebody_up: 5, shoes: 7, accessories_up: 7 };
export const wearsFor = (item) => Number.isInteger(item?.wears) ? item.wears : DEFAULT_WEARS[item?.part] ?? 1;

const dayNumber = (date) => Date.parse(`${date}T00:00:00Z`) / DAY;
const comboKey = (ids) => [...ids].sort().join("+");

export const planSchema = {
  type: "object",
  additionalProperties: false,
  properties: {
    outfits: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          date: { type: "string" },
          name: { type: "string" },
          garmentIds: { type: "array", items: { type: "string" } },
          reason: { type: "string" },
        },
        required: ["date", "name", "garmentIds", "reason"],
      },
    },
  },
  required: ["outfits"],
};

// Plans for other dates near the requested range: what the model must avoid repeating.
export function historyFor(plans, dates) {
  const targets = dates.map(dayNumber);
  const first = Math.min(...targets) - 30;
  const last = Math.max(...targets) + SPACING_DAYS;
  return Object.values(plans)
    .filter((plan) => !dates.includes(plan.date) && dayNumber(plan.date) >= first && dayNumber(plan.date) <= last)
    .sort((a, b) => a.date.localeCompare(b.date))
    .map(({ date, garmentIds }) => ({ date, garmentIds }));
}

export function buildPlanPrompt({ items, days, history }) {
  // Each piece carries the nearby dates it is already worn on, so rotation doesn't need cross-referencing ids.
  const wardrobe = items.map((item) => ({ ...pick(item), wears: wearsFor(item), wornOn: history.filter((plan) => plan.garmentIds.includes(item.id)).map((plan) => plan.date) }));
  return `You are a personal stylist planning outfits from a real wardrobe.

Plan exactly one outfit for each requested day:
${JSON.stringify(days)}

Available wardrobe (only these garments may be used; anything else is in the laundry or unavailable). wornOn lists nearby dates each piece is already worn:
${JSON.stringify(wardrobe)}

Outfits already worn or planned on nearby dates:
${JSON.stringify(history)}

How to style each day:
- Picture three genuinely different outfits first, each with its own color story (for example tonal neutrals, light top over a dark bottom, one warm accent color), then keep the strongest. Neighbouring days should not all share one color story.
- Build from the bottom and the layers outward: the bottom and any midlayer or outer layer set the outfit's shape and colors; then pick a base top that works under them, and shoes last.
- Use the pieces' hex colors: aim for a clear light-dark contrast between pieces or a deliberate tonal look, keep to one statement color or graphic, and avoid colors that almost but don't quite match (two different browns, two slightly different greys).
- Read each garment's description and text: pair pieces whose fabric, warmth and formality suit each other, and never combine two loud graphics or slogans in one outfit. Under a hoodie or sweater, prefer a plain or small-logo base top.
- Match each day's requested style.

Structure:
- Each outfit has exactly one upperbody base top (t-shirt, shirt) and one lowerbody bottom, plus optional midlayer (hoodie, sweater), wholebody_up outer layer (jacket, coat, rain jacket), shoes, and at most one accessories_up item. A midlayer or outer layer never replaces the base top; it goes over it, so a cold day can stack base top + midlayer + outer layer.
- Dress for each day's weather: warm means base top only, no midlayer or outer layer; mild allows one light layer when the style suits it; cold needs a midlayer, plus an outer layer when one is available; rain needs an outer layer when one is available, plus a midlayer if it is also chilly; auto means judge from the date's usual season.
- palette is the day's color preference: any means no preference; neutral means black, white, grey, beige, navy and denim; muted means soft, desaturated colors; bold means one or two saturated statement colors; monochrome means one color family head to toe.
- A day with include must contain that garment id; build the rest of the outfit around it.
- note is the user's own words about the day (plans, dress code, activities, how they feel). Follow it where the wardrobe allows and mention it in the reason.

Rotation:
- wears is how many times a garment can be worn before it needs washing; it is a limit, not a target. Within ${SPACING_DAYS} days either side of any date, a garment may be worn on at most wears dates in total, counting the history and the other days in this plan. Only go past a limit when the wardrobe has no alternative for that part; then reuse the one worn longest ago.
- Rotate within each part: prefer the piece with the fewest wornOn dates and the fewest uses in this plan. Wearing the same bottom two days in a row is fine, but spread all the bottoms and all the midlayers across the days instead of building most outfits on one favorite.
- Never put the same two pieces together again within ${SPACING_DAYS} days: not the same bottom with the same midlayer or outer layer, and not the same base top with the same bottom.
- Never repeat an exact garment combination from the history or within this plan.
- Every requested date must get a complete outfit. When the wardrobe is too small for these preferences, repeat the least recently worn pieces rather than leaving a day empty.

Restyles and swaps:
- A day with avoid is being restyled: the user has already seen those outfits and wants something else. Give it a clearly different outfit from every one in avoid: change the bottom or the layer, change the base top, and use a different color story. Swapping a single piece is not enough.
- A day with replace is a swap: keep that day's keep garments and replace only the replace garment with a different garment of the same part.

Use exact ids from the wardrobe list. name is a short evocative outfit title; reason is one sentence on why it works for the style and colors.

Return JSON with an outfits array containing one entry per requested date.`;
}

const pick = ({ id, name, part, color, secondaryColor, description, text, backText, tags }) => ({ id, name, part, color, secondaryColor, description, text, backText, tags });

// Keeps only real, available garments, at most one per part, and fails dates without a top and a bottom.
export function validatePlan(result, { items, days }) {
  const byId = new Map(items.map((item) => [item.id, item]));
  const outfits = new Map((result?.outfits || []).map((outfit) => [outfit.date, outfit]));
  return days.map(({ date, style, weather, palette, include, note }) => {
    const outfit = outfits.get(date);
    const seen = new Set();
    const garmentIds = [...new Set(outfit?.garmentIds || [])].filter((id) => {
      const part = byId.get(id)?.part;
      if (!part || seen.has(part)) return false;
      seen.add(part);
      return true;
    });
    if (!seen.has("upperbody") || !seen.has("lowerbody")) throw new Error(`The stylist returned no usable outfit for ${date}`);
    return { date, style, weather, palette, include, note, name: String(outfit.name || "Outfit").slice(0, 80), garmentIds, reason: String(outfit.reason || "").slice(0, 400) };
  });
}

// How often each garment is worn within SPACING_DAYS of date, not counting date itself.
function wornNear(plans, date) {
  const target = dayNumber(date);
  const worn = new Map();
  for (const plan of Object.values(plans)) {
    if (plan.date !== date && Math.abs(dayNumber(plan.date) - target) <= SPACING_DAYS) plan.garmentIds.forEach((id) => worn.set(id, (worn.get(id) || 0) + 1));
  }
  return worn;
}

// Garment ids on date that go past their wear limit nearby; the app uses this to flag repeats.
export function repeatedGarments(plans, date, items = []) {
  const worn = wornNear(plans, date);
  const byId = new Map(items.map((item) => [item.id, item]));
  return (plans[date]?.garmentIds || []).filter((id) => (worn.get(id) || 0) >= wearsFor(byId.get(id)));
}

// Avoidable rule breaks in a fresh plan: a recent garment reused while an unused same-part garment existed, or a repeated combo.
export function planIssues(plans, planned, items) {
  const merged = { ...plans, ...Object.fromEntries(planned.map((plan) => [plan.date, plan])) };
  const byId = new Map(items.map((item) => [item.id, item]));
  const issues = [];
  for (const { date } of planned) {
    const worn = wornNear(merged, date);
    for (const id of repeatedGarments(merged, date, items)) {
      const part = byId.get(id)?.part;
      if (items.some((item) => item.part === part && (worn.get(item.id) || 0) < wearsFor(item))) issues.push(`${date} wears ${id} past its wash limit although other ${part} items are free`);
    }
  }
  const dates = new Set(planned.map((plan) => plan.date));
  // One top and one bottom leave no way to avoid repeating the combination.
  const count = (part) => items.filter((item) => item.part === part).length;
  if (count("upperbody") > 1 || count("lowerbody") > 1) {
    for (const date of duplicateCombos(merged)) if (dates.has(date)) issues.push(`${date} repeats an earlier outfit combination`);
  }
  return issues;
}

// Layers that ignore the day's weather although the wardrobe could have followed it.
export function layerIssues(days, planned, items) {
  const parts = (date) => new Set((planned.find((plan) => plan.date === date)?.garmentIds || []).map((id) => items.find((item) => item.id === id)?.part));
  const has = (part) => items.some((item) => item.part === part);
  return days.filter((day) => !day.replace).flatMap(({ date, weather }) => {
    const worn = parts(date);
    if (weather === "warm" && (worn.has("midlayer") || worn.has("wholebody_up"))) return [`${date} is warm: drop the midlayer and outer layer`];
    if (weather === "cold" && has("midlayer") && !worn.has("midlayer")) return [`${date} is cold: add a midlayer over the base top`];
    if (weather === "rain" && has("wholebody_up") && !worn.has("wholebody_up")) return [`${date} is rainy: add an outer layer`];
    return [];
  });
}

// Days that named a piece to build around but didn't get it.
export function includeIssues(days, planned) {
  return days.filter((day) => day.include && !day.replace).flatMap(({ date, include }) => {
    const ids = planned.find((plan) => plan.date === date)?.garmentIds || [];
    return ids.includes(include) ? [] : [`${date} must include ${include}`];
  });
}

// Swaps that kept every other piece and put one different piece of the same part in place of the swapped one pass.
export function swapIssues(days, planned, library) {
  const partOf = new Map(library.map((item) => [item.id, item.part]));
  return days.filter((day) => day.replace).flatMap(({ date, replace, keep }) => {
    const ids = planned.find((plan) => plan.date === date)?.garmentIds || [];
    const part = partOf.get(replace);
    const swapped = ids.length === keep.length + 1 && keep.every((id) => ids.includes(id)) && ids.some((id) => id !== replace && !keep.includes(id) && partOf.get(id) === part);
    return swapped ? [] : [`${date} must keep ${keep.join(", ") || "nothing else"} and replace only ${replace} with another ${part}`];
  });
}

// Every date whose exact garment combination also appears on another date.
export function duplicateCombos(plans) {
  const groups = new Map();
  for (const plan of Object.values(plans)) groups.set(comboKey(plan.garmentIds), [...(groups.get(comboKey(plan.garmentIds)) || []), plan.date]);
  return [...groups.values()].filter((dates) => dates.length > 1).flat();
}

// Parts that make an outfit's look; shoes and accessories repeat too often to count.
const LOOK = new Set(["upperbody", "midlayer", "wholebody_up", "lowerbody"]);
// Parts a closet usually has a few of, which should take turns.
const ROTATING = ["lowerbody", "midlayer", "wholebody_up"];
const near = (a, b) => a !== b && Math.abs(dayNumber(a) - dayNumber(b)) <= SPACING_DAYS;

// Fresh days that put the same two look pieces together as another day close by, e.g. the same jeans and hoodie.
export function pairIssues(plans, planned, items) {
  const merged = { ...plans, ...Object.fromEntries(planned.map((plan) => [plan.date, plan])) };
  const partOf = new Map(items.map((item) => [item.id, item.part]));
  const look = (ids) => ids.filter((id) => LOOK.has(partOf.get(id)));
  return planned.flatMap(({ date, garmentIds }) => {
    const mine = look(garmentIds);
    for (const other of Object.values(merged)) {
      if (!near(date, other.date)) continue;
      const shared = mine.filter((id) => other.garmentIds.includes(id));
      if (shared.length >= 2) return [`${date} pairs ${shared.join(" with ")} again, as on ${other.date}: change one of them`];
    }
    return [];
  });
}

// Fresh days that lean on one piece while another of the same part sits unworn nearby.
export function rotationIssues(plans, planned, items, days = []) {
  const merged = { ...plans, ...Object.fromEntries(planned.map((plan) => [plan.date, plan])) };
  const byId = new Map(items.map((item) => [item.id, item]));
  const uses = (id, date) => Object.values(merged).filter((plan) => near(date, plan.date) && plan.garmentIds.includes(id)).length;
  return planned.flatMap(({ date, garmentIds }) => {
    const day = days.find((entry) => entry.date === date);
    return garmentIds.flatMap((id) => {
      const part = byId.get(id)?.part;
      if (!ROTATING.includes(part) || id === day?.include) return [];
      const others = items.filter((item) => item.part === part && item.id !== id).map((item) => ({ id: item.id, count: uses(item.id, date) }));
      const least = others.sort((a, b) => a.count - b.count)[0];
      const count = uses(id, date);
      // One extra wear is fine (the same jeans two days running); two more than a sibling is leaning on a favorite.
      return least && count - least.count >= 2 ? [`${date} wears ${id} on ${count + 1} nearby days while ${least.id} is worn on ${least.count}: rotate to a less worn ${part}`] : [];
    });
  });
}

// Restyles that came back to an outfit the user already saw, or changed too little of the current one.
export function restyleIssues(days, planned, items) {
  const partOf = new Map(items.map((item) => [item.id, item.part]));
  return days.filter((day) => day.avoid?.length && !day.replace).flatMap(({ date, avoid }) => {
    const ids = planned.find((plan) => plan.date === date)?.garmentIds || [];
    if (avoid.some((seen) => comboKey(seen) === comboKey(ids))) return [`${date} repeats an outfit the user already rejected`];
    // Measured against every outfit seen, so a restyle can't drift back to an earlier one with one piece changed.
    const changed = Math.min(...avoid.map((seen) => ids.filter((id) => LOOK.has(partOf.get(id)) && !seen.includes(id)).length));
    return changed >= 2 ? [] : [`${date} is a restyle but differs by only ${changed} piece${changed === 1 ? "" : "s"} from an outfit the user already saw: change at least the base top and the bottom or layer`];
  });
}
