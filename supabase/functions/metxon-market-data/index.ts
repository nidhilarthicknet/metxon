import { createClient } from 'npm:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
}
const url = Deno.env.get('SUPABASE_URL')!
const publishableKeys = JSON.parse(Deno.env.get('SUPABASE_PUBLISHABLE_KEYS') || '{}')
const secretKeys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') || '{}')
const pub = publishableKeys.default
const secretKey = secretKeys.default

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
}
function num(v: unknown) {
  const n = Number(v)
  return Number.isFinite(n) ? n : null
}
function cleanTicker(v: unknown) {
  const t = String(v ?? '').trim().toUpperCase()
  if (!/^[A-Z0-9.^=-]{1,20}$/.test(t)) throw new Error('Invalid ticker')
  return t
}
async function yahoo(symbol: string) {
  const u = 'https://query1.finance.yahoo.com/v8/finance/chart/' + encodeURIComponent(symbol) + '?range=1mo&interval=1d&includePrePost=false&events=div%2Csplits'
  const r = await fetch(u, { headers: { 'User-Agent': 'Metxon/1.0' } })
  if (!r.ok) throw new Error('Market data request failed (' + r.status + ')')
  const j = await r.json()
  const x = j?.chart?.result?.[0]
  if (!x) throw new Error('No market data found for this ticker')
  return x
}

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  try {
    const auth = req.headers.get('Authorization') || ''
    const token = auth.startsWith('Bearer ') ? auth.slice(7) : ''
    if (!token) return json({ error: 'Authentication required' }, 401)
    const userClient = createClient(url, pub, {
      global: { headers: { Authorization: 'Bearer ' + token } },
      auth: { autoRefreshToken: false, persistSession: false }
    })
    const { data: userData, error: userError } = await userClient.auth.getUser()
    if (userError || !userData.user) return json({ error: 'Invalid session' }, 401)

    const body = await req.json()
    const ticker = cleanTicker(body.ticker)
    const raw = await yahoo(ticker)
    const meta = raw.meta || {}
    const quote = raw?.indicators?.quote?.[0] || {}
    const closes = (quote.close || []).map(num).filter((n: number | null): n is number => n !== null)
    const current = num(meta.regularMarketPrice) ?? closes.at(-1)
    const previous = num(meta.chartPreviousClose) ?? closes.at(-2) ?? current
    if (current == null) return json({ error: 'Current market price unavailable' }, 400)
    const highs = (quote.high || []).map(num).filter((n: number | null): n is number => n !== null)
    const lows = (quote.low || []).map(num).filter((n: number | null): n is number => n !== null)
    const market = {
      ticker,
      currency: meta.currency || 'USD',
      exchange: meta.exchangeName || null,
      marketState: meta.marketState || null,
      currentPrice: current,
      previousClose: previous,
      todayChangePct: previous ? ((current - previous) / previous) * 100 : null,
      dayHigh: num(meta.regularMarketDayHigh) ?? Math.max(...highs.slice(-1), current),
      dayLow: num(meta.regularMarketDayLow) ?? Math.min(...lows.slice(-1), current),
      oneMonthChangePct: closes[0] ? ((current - closes[0]) / closes[0]) * 100 : 0,
      oneMonthHigh: Math.max(...closes, current),
      oneMonthLow: Math.min(...closes, current),
      asOf: new Date().toISOString()
    }
    if (!secretKey) return json({ error: 'Market quote storage is not configured. Trading is temporarily unavailable.' }, 503)
    const admin = createClient(url, secretKey, { auth: { autoRefreshToken: false, persistSession: false } })
    const { error: saveError } = await admin.from('market_snapshots').insert({ ticker, as_of: market.asOf, payload: market })
    if (saveError) {
      console.error('Market snapshot save failed:', saveError.message)
      return json({ error: 'Quote fetched but not recorded for secure trading. Try again later.' }, 503)
    }
    return json({
      ticker,
      market,
      source: 'Yahoo Finance chart data',
      tradeable: true,
      disclaimer: 'Market data may be delayed. Informational only.'
    })
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : 'Unexpected error' }, 400)
  }
})