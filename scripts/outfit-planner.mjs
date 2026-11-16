const DAY = 24 * 60 * 60 * 1000;
export const DATE = /^\d{4}-\d{2}-\d{2}$/;
// Garments worn within this many days of a target date count as "recent".
export const SPACING_DAYS = 4;

// How many times a piece is usually worn before it needs washing, when the user hasn't set it.
export const DEFAULT_WEARS = { upperbody: 1, lowerbody: 3, wholebody_up: 5, shoes: 7, accessories_up: 7 };
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
  const wardrobe = items.map((item) => ({ ...pick(item), wears: wearsFor(item) }));
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
- wears is how many times a garment can be worn before it needs washing. Within ${SPACING_DAYS} days either side of any date, a garment may be worn on at most wears dates in total, counting the history and the other days in this plan. So a wears-1 tee should not repeat within ${SPACING_DAYS} days, while wears-3 jeans can be worn on up to three close or consecutive days. Only go past a limit when the wardrobe has no alternative for that part; then reuse the one worn longest ago, preferring neutral basics.
- Never repeat an exact garment combination from the history or within this plan.
- Spread usage across the whole wardrobe instead of leaning on the same favorites.
- Every requested date must get a complete outfit. The repetition rules are preferences: when the wardrobe is too small to satisfy them, repeat the least recently worn pieces rather than leaving a day empty.
- A day with replace is a swap: keep that day's keep garments and replace only the replace garment with a different garment of the same part.
- Use exact ids from the wardrobe list. name is a short evocative outfit title; reason is one sentence on why it works for the style.

Return JSON with an outfits array containing one entry per requested date.`;
}

const pick = ({ id, name, part, color, secondaryColor, tags }) => ({ id, name, part, color, secondaryColor, tags });

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

// Every date whose exact garment combination also appears on another date.
export function duplicateCombos(plans) {
  const groups = new Map();
  for (const plan of Object.values(plans)) groups.set(comboKey(plan.garmentIds), [...(groups.get(comboKey(plan.garmentIds)) || []), plan.date]);
  return [...groups.values()].filter((dates) => dates.length > 1).flat();
}
