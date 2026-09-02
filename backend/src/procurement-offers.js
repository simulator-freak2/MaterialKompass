const MAX_MONEY_CENTS = 100_000_000_000;
const MAX_OFFER_COMPONENTS = 50;
const MAX_DELIVERY_DAYS = 3650;

function parseMoneyCents(value, { signed = false } = {}) {
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) return null;
    const cents = Math.round(value * 100);
    return (!signed && cents < 0) || Math.abs(cents) > MAX_MONEY_CENTS ? null : cents;
  }
  const raw = String(value ?? '').trim().replace(/\s/g, '');
  if (!raw) return null;
  const normalized = raw.includes(',')
    ? raw.replace(/\./g, '').replace(',', '.')
    : raw;
  if (!/^[+-]?\d+(?:\.\d{1,2})?$/.test(normalized)) return null;
  const parsed = Number(normalized);
  if (!Number.isFinite(parsed)) return null;
  const cents = Math.round(parsed * 100);
  return (!signed && cents < 0) || Math.abs(cents) > MAX_MONEY_CENTS ? null : cents;
}

function euros(cents) {
  return Math.round(cents) / 100;
}

function validDate(value) {
  if (value == null || value === '') return true;
  const text = String(value);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(text)) return false;
  const date = new Date(`${text}T00:00:00.000Z`);
  return !Number.isNaN(date.valueOf()) && date.toISOString().slice(0, 10) === text;
}

function normalizeOfferInput(body, request) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    return { error: 'Die Angebotsdaten sind ungültig.' };
  }
  const requestItems = Array.isArray(request?.items) ? request.items : [];
  if (!Array.isArray(body.items) || body.items.length !== requestItems.length) {
    return { error: 'Für jede Antragsposition ist eine Angebotsposition erforderlich.' };
  }
  const requestItemIds = new Set(requestItems.map((item) => String(item.id)));
  const seenItemIds = new Set();
  const items = [];
  let positionsCents = 0;
  for (const raw of body.items) {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
      return { error: 'Mindestens eine Angebotsposition ist ungültig.' };
    }
    const requestItemId = String(raw.requestItemId || '');
    if (!requestItemIds.has(requestItemId) || seenItemIds.has(requestItemId)) {
      return { error: 'Angebotspositionen müssen eindeutig zu den Antragspositionen gehören.' };
    }
    seenItemIds.add(requestItemId);
    const offered = raw.offered !== false;
    const grossCents = parseMoneyCents(raw.grossTotal ?? 0);
    if (grossCents == null || (offered && grossCents <= 0) || (!offered && grossCents !== 0)) {
      return { error: offered
        ? 'Jede angebotene Position benötigt eine positive Brutto-Positionssumme.'
        : 'Nicht angebotene Positionen müssen eine Positionssumme von 0,00 EUR haben.' };
    }
    positionsCents += grossCents;
    if (positionsCents > MAX_MONEY_CENTS) return { error: 'Die Summe der Angebotspositionen ist zu hoch.' };
    items.push({ requestItemId, offered, grossTotal: euros(grossCents) });
  }
  if (!items.some((item) => item.offered)) {
    return { error: 'Mindestens eine Position muss angeboten werden.' };
  }

  if (!Array.isArray(body.components) || body.components.length > MAX_OFFER_COMPONENTS) {
    return { error: `Es sind höchstens ${MAX_OFFER_COMPONENTS} zusätzliche Angebotsbestandteile erlaubt.` };
  }
  const components = [];
  let shippingCount = 0;
  let discountCount = 0;
  let componentsCents = 0;
  for (let index = 0; index < body.components.length; index += 1) {
    const raw = body.components[index];
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
      return { error: 'Mindestens ein zusätzlicher Angebotsbestandteil ist ungültig.' };
    }
    const kind = ['shipping', 'discount'].includes(raw.kind) ? raw.kind : 'custom';
    if (kind === 'shipping') shippingCount += 1;
    if (kind === 'discount') discountCount += 1;
    const label = kind === 'shipping'
      ? 'Versandkosten'
      : kind === 'discount'
        ? 'Rabatt'
        : String(raw.label || '').trim();
    if (!label || label.length > 100) {
      return { error: 'Zusätzliche Angebotsbestandteile benötigen eine Bezeichnung mit höchstens 100 Zeichen.' };
    }
    const operation = kind === 'shipping' ? 'add'
      : kind === 'discount' ? 'subtract'
        : raw.operation === 'subtract' ? 'subtract' : 'add';
    const grossCents = parseMoneyCents(raw.grossAmount ?? 0, { signed: kind === 'discount' });
    if (grossCents == null || (kind !== 'discount' && grossCents < 0)) {
      return { error: kind === 'shipping'
        ? 'Versandkosten dürfen nicht negativ sein.'
        : 'Der Betrag eines zusätzlichen Angebotsbestandteils ist ungültig.' };
    }
    componentsCents += operation === 'subtract' ? -grossCents : grossCents;
    components.push({
      id: `component-${index + 1}`,
      kind,
      label,
      operation,
      grossAmount: euros(grossCents),
    });
  }
  if (shippingCount !== 1 || discountCount !== 1) {
    return { error: 'Versandkosten und Rabatt müssen jeweils genau einmal angegeben werden.' };
  }

  const calculatedCents = positionsCents + componentsCents;
  if (calculatedCents <= 0 || calculatedCents > MAX_MONEY_CENTS) {
    return { error: 'Die berechnete Angebotssumme muss größer als null und innerhalb des zulässigen Bereichs sein.' };
  }
  const documentCents = parseMoneyCents(body.documentGrossTotal);
  if (documentCents == null || documentCents <= 0) {
    return { error: 'Die Brutto-Gesamtsumme laut Angebotsdokument ist erforderlich.' };
  }
  if (documentCents !== calculatedCents) {
    return {
      error: `Die Eingabe weicht um ${euros(documentCents - calculatedCents).toFixed(2)} EUR von der Angebotssumme ab.`,
    };
  }

  const offerNumber = String(body.offerNumber || '').trim();
  const notes = String(body.notes || '').trim();
  const deliveryText = body.deliveryDays == null ? '' : String(body.deliveryDays).trim();
  const deliveryDays = deliveryText === '' ? null : Number(deliveryText);
  if (offerNumber.length > 128 || notes.length > 5000
      || !validDate(body.offerDate) || !validDate(body.validUntil)
      || (deliveryDays != null && (!Number.isInteger(deliveryDays)
        || deliveryDays <= 0 || deliveryDays > MAX_DELIVERY_DAYS))) {
    return { error: 'Angebotsnummer, Datum, Lieferzeit oder Notiz ist ungültig.' };
  }
  const shipping = components.find((entry) => entry.kind === 'shipping');
  const discount = components.find((entry) => entry.kind === 'discount');
  return {
    value: {
      offerNumber,
      offerDate: body.offerDate || null,
      validUntil: body.validUntil || null,
      deliveryDays,
      items,
      components,
      positionsGrossTotal: euros(positionsCents),
      componentsGrossTotal: euros(componentsCents),
      calculatedGrossTotal: euros(calculatedCents),
      documentGrossTotal: euros(documentCents),
      // Keep the legacy split fields so old clients and exports remain readable.
      grossTotal: euros(calculatedCents - Math.round(shipping.grossAmount * 100)),
      shippingGross: shipping.grossAmount,
      discountGross: discount.grossAmount,
      notes,
    },
  };
}

function offerGrandTotal(offer) {
  const explicit = Number(offer?.calculatedGrossTotal);
  if (Number.isFinite(explicit)) return Math.round(explicit * 100) / 100;
  const gross = Number(offer?.grossTotal) || 0;
  const shipping = Number(offer?.shippingGross) || 0;
  return Math.round((gross + shipping) * 100) / 100;
}

module.exports = { normalizeOfferInput, offerGrandTotal };
