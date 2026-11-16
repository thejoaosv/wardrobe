const DAY = 24 * 60 * 60 * 1000;
export const DATE = /^\d{4}-\d{2}-\d{2}$/;
// Garments worn within this many days of a target date count as "recent".
export const SPACING_DAYS = 4;

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
  const wardrobe = items.map(({ id, name, part, color, secondaryColor, tags }) => ({ id, name, part, color, secondaryColor, tags }));
  return `You are a personal stylist planning outfits from a real wardrobe.

Plan exactly one outfit for each requested day:
${JSON.stringify(days)}

Available wardrobe (only these garments may be used; anything else is in the laundry or unavailable):
${JSON.stringify(wardrobe)}

Outfits already worn or planned on nearby dates:
${JSON.stringify(history)}

Rules:
- Each outfit has one upperbody top and one lowerbody bottom, plus optional wholebody_up outer layer, shoes, and at most one accessories_up item.
- Match each day's requested style. Use color harmony: tonal or analogous palettes, one statement piece at most.
- Do not repeat a garment within ${SPACING_DAYS} days of another date where it is worn, counting both the history and the other days in this plan. Only reuse a garment sooner when the wardrobe has no alternative for that part; then reuse the one worn longest ago, preferring neutral basics.
- Never repeat an exact garment combination from the history or within this plan.
- Spread usage across the whole wardrobe instead of leaning on the same favorites.
- Every requested date must get a complete outfit. The repetition rules are preferences: when the wardrobe is too small to satisfy them, repeat the least recently worn pieces rather than leaving a day empty.
- Use exact ids from the wardrobe list. name is a short evocative outfit title; reason is one sentence on why it works for the style.

Return JSON with an outfits array containing one entry per requested date.`;
}

// Keeps only real, available garments, at most one per part (accessories excepted), and fails dates the model skipped.
export function validatePlan(result, { items, days }) {
  const byId = new Map(items.map((item) => [item.id, item]));
  const outfits = new Map((result?.outfits || []).map((outfit) => [outfit.date, outfit]));
  return days.map(({ date, style }) => {
    const outfit = outfits.get(date);
    const seen = new Set();
    const garmentIds = [...new Set(outfit?.garmentIds || [])].filter((id) => {
      const part = byId.get(id)?.part;
      if (!part || (part !== "accessories_up" && seen.has(part))) return false;
      seen.add(part);
      return true;
    });
    if (!garmentIds.length) throw new Error(`The stylist returned no usable outfit for ${date}`);
    return { date, style, name: String(outfit.name || "Outfit").slice(0, 80), garmentIds, reason: String(outfit.reason || "").slice(0, 400) };
  });
}

// Garment ids worn within SPACING_DAYS of date in the given plans; the app uses this to flag repeats.
export function repeatedGarments(plans, date) {
  const target = dayNumber(date);
  const recent = new Set();
  for (const plan of Object.values(plans)) {
    if (plan.date !== date && Math.abs(dayNumber(plan.date) - target) <= SPACING_DAYS) plan.garmentIds.forEach((id) => recent.add(id));
  }
  return (plans[date]?.garmentIds || []).filter((id) => recent.has(id));
}

// Avoidable rule breaks in a fresh plan: a recent garment reused while an unused same-part garment existed, or a repeated combo.
export function planIssues(plans, planned, items) {
  const merged = { ...plans, ...Object.fromEntries(planned.map((plan) => [plan.date, plan])) };
  const byId = new Map(items.map((item) => [item.id, item]));
  const issues = [];
  for (const { date } of planned) {
    const target = dayNumber(date);
    const nearby = new Set(Object.values(merged)
      .filter((plan) => plan.date !== date && Math.abs(dayNumber(plan.date) - target) <= SPACING_DAYS)
      .flatMap((plan) => plan.garmentIds));
    for (const id of repeatedGarments(merged, date)) {
      const part = byId.get(id)?.part;
      if (items.some((item) => item.part === part && !nearby.has(item.id))) issues.push(`${date} reuses ${id} although other ${part} items are free`);
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

// Every date whose exact garment combination also appears on another date.
export function duplicateCombos(plans) {
  const groups = new Map();
  for (const plan of Object.values(plans)) groups.set(comboKey(plan.garmentIds), [...(groups.get(comboKey(plan.garmentIds)) || []), plan.date]);
  return [...groups.values()].filter((dates) => dates.length > 1).flat();
}
