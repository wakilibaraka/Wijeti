import { React, run } from "uebersicht";

// Five-day forecast from Open-Meteo. No API key required.

const ENDPOINT = "https://api.open-meteo.com/v1/forecast";

export const refreshFrequency = 30 * 60 * 1000;

export const className = `
  position: absolute;
  inset: 0;
  pointer-events: none;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  color: #fff;

  .card {
    position: absolute;
    top: 40px;
    right: 40px;
    width: 250px;
    padding: 16px 18px;
    border-radius: 22px;
    background: rgba(10, 14, 24, 0.55);
    border: 1px solid rgba(255, 255, 255, 0.12);
    box-shadow: 0 10px 30px rgba(0, 0, 0, 0.25);
    backdrop-filter: blur(18px);
    -webkit-backdrop-filter: blur(18px);
    box-sizing: border-box;
  }

  .head { font-size: 12px; opacity: 0.6; margin-bottom: 12px; letter-spacing: 0.06em; text-transform: uppercase; }
  .day { display: flex; align-items: baseline; justify-content: space-between; padding: 7px 0; }
  .day + .day { border-top: 1px solid rgba(255, 255, 255, 0.08); }
  .name { font-size: 14px; }
  .lo { font-size: 13px; opacity: 0.55; }
  .hi { font-size: 15px; }
  .err { color: #ffb4a2; font-size: 12px; line-height: 1.5; }
`;

const DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

export const render = ({ output, error }) => {
  if (error) {
    return <div className="card"><div className="err">{error}</div></div>;
  }
  if (!output || !output.trim()) {
    // `run()` also resolves with an empty string when the command produced nothing —
    // no network, a proxy that ate the body, or curl not on PATH.
    return <div className="card"><div className="head">Forecast</div><div className="lo">Loading…</div></div>;
  }

  let data;
  try {
    data = JSON.parse(output);
  } catch (e) {
    return <div className="card"><div className="err">Could not read the forecast.</div></div>;
  }
  if (data.error) {
    return <div className="card"><div className="err">{data.reason || "Forecast unavailable"}</div></div>;
  }

  const daily = data.daily || {};
  const times = daily.time || [];
  const rows = times.slice(0, 5).map((iso, index) => ({
    name: DAYS[new Date(iso + "T00:00:00").getDay()],
    hi: Math.round(daily.temperature_2m_max[index]),
    lo: Math.round(daily.temperature_2m_min[index]),
  }));

  return (
    <div className="card">
      <div className="head">Next 5 days</div>
      {rows.map((row) => (
        <div className="day" key={row.name}>
          <span className="name">{row.name}</span>
          <span className="lo">{row.lo}°</span>
          <span className="hi">{row.hi}°</span>
        </div>
      ))}
    </div>
  );
};

export const init = (dispatch) => {
  run(`
    curl -s '${ENDPOINT}?daily=temperature_2m_max,temperature_2m_min&forecast_days=5&timezone=auto'
  `)
    .then((output) => dispatch({ type: "UB/COMMAND_RAN", output }))
    .catch((err) => dispatch({ type: "UB/COMMAND_RAN", error: String(err) }));
};
