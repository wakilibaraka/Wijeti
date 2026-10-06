// Crypto Ticker — Bitcoin and Ethereum prices with 24h change (CoinGecko).

export const command = `
json=$(curl -s --max-time 8 "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum&vs_currencies=usd&include_24hr_change=true")
if [ -z "$json" ]; then
  echo NEEDS_NET
else
  printf '%s' "$json"
fi
`;

export const refreshFrequency = 120000;

export const className = `
  position: fixed;
  right: 24px;
  bottom: 24px;
  width: 232px;
  box-sizing: border-box;
  padding: 14px 16px;
  background: rgba(18, 18, 22, 0.62);
  -webkit-backdrop-filter: blur(24px);
  border: 1px solid rgba(255, 255, 255, 0.14);
  border-radius: 16px;
  color: #f5f5f7;
  font-family: -apple-system, 'Helvetica Neue';
  font-size: 13px;

  .title {
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    opacity: 0.55;
    margin-bottom: 10px;
  }

  .coin {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    margin-bottom: 8px;
  }

  .coin:last-child {
    margin-bottom: 0;
  }

  .name {
    font-weight: 500;
  }

  .price {
    font-variant-numeric: tabular-nums;
    font-weight: 600;
  }

  .change {
    font-size: 11px;
    margin-left: 6px;
  }

  .up {
    color: #30d158;
  }

  .down {
    color: #ff453a;
  }

  .muted {
    opacity: 0.65;
    font-size: 12px;
    line-height: 1.45;
  }
`;

const Coin = ({ symbol, name, data }) => {
  const price = data && data.usd;
  const change = (data && data.usd_24h_change) || 0;
  if (price === undefined) return null;
  const up = change >= 0;
  return (
    <div className="coin">
      <span className="name">
        {symbol} {name}
      </span>
      <span>
        <span className="price">
          $
          {Number(price).toLocaleString("en-US", { maximumFractionDigits: price < 10 ? 2 : 0 })}
        </span>
        <span className={`change ${up ? "up" : "down"}`}>
          {up ? "▲" : "▼"} {Math.abs(change).toFixed(2)}%
        </span>
      </span>
    </div>
  );
};

export const render = ({ output, error }) => {
  if (error || (output || "").trim() === "NEEDS_NET") {
    return (
      <div>
        <div className="title">Crypto</div>
        <div className="muted">Needs internet access — prices will load when you're back online.</div>
      </div>
    );
  }
  if (!(output || "").trim()) {
    return (
      <div>
        <div className="title">Crypto</div>
        <div className="muted">Fetching prices…</div>
      </div>
    );
  }
  let data;
  try {
    data = JSON.parse(output);
  } catch (e) {
    return (
      <div>
        <div className="title">Crypto</div>
        <div className="muted">Needs internet access — the price service returned something unexpected.</div>
      </div>
    );
  }
  return (
    <div>
      <div className="title">Crypto · USD</div>
      <Coin symbol="₿" name="Bitcoin" data={data.bitcoin} />
      <Coin symbol="◆" name="Ethereum" data={data.ethereum} />
    </div>
  );
};
