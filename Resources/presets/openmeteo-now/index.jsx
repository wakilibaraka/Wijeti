import { React, run } from "uebersicht";

// Current conditions from Open-Meteo. No API key, no account, CORS-friendly.
// https://api.open-meteo.com/v1/forecast

const ENDPOINT = "https://api.open-meteo.com/v1/forecast";

export const refreshFrequency = 10 * 60 * 1000;

export const className = `
  position: absolute;
  inset: 0;
  pointer-events: none;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  color: #fff;

  .card {
    position: absolute;
    top: 40px;
    left: 40px;
    width: 230px;
    padding: 18px 20px;
    border-radius: 22px;
    background: rgba(10, 14, 24, 0.55);
    border: 1px solid rgba(255, 255, 255, 0.12);
    box-shadow: 0 10px 30px rgba(0, 0, 0, 0.25);
    backdrop-filter: blur(18px);
    -webkit-backdrop-filter: blur(18px);
    box-sizing: border-box;
  }

  .place { font-size: 13px; opacity: 0.65; margin-bottom: 10px; }
  .temp { font-size: 52px; font-weight: 200; line-height: 1; }
  .temp sup { font-size: 20px; font-weight: 300; vertical-align: top; }
  .desc { font-size: 14px; opacity: 0.8; margin-top: 8px; }
  .meta { font-size: 12px; opacity: 0.55; margin-top: 12px; }
  .err { color: #ffb4a2; font-size: 12px; line-height: 1.5; }
`;

const WMO = {
  0: "Clear sky",
  1: "Mainly clear",
  2: "Partly cloudy",
  3: "Overcast",
  45: "Fog",
  48: "Rime fog",
  51: "Light drizzle",
  53: "Drizzle",
  55: "Heavy drizzle",
  61: "Light rain",
  63: "Rain",
  65: "Heavy rain",
  71: "Light snow",
  73: "Snow",
  75: "Heavy snow",
  80: "Rain showers",
  95: "Thunderstorm",
};

function describe(code) {
  return WMO[code] || "Unknown";
}

export const render = ({ output, error }) => {
  if (error) {
    return <div className="card"><div className="err">{error}</div></div>;
  }
  if (!output || !output.trim()) {
    // `run()` also resolves with an empty string when the command produced nothing —
    // no network, a proxy that ate the body, or curl not on PATH.
    return <div className="card"><div className="desc">Loading weather…</div></div>;
  }

  let data;
  try {
    data = JSON.parse(output);
  } catch (e) {
    return <div className="card"><div className="err">Could not read the forecast.</div></div>;
  }
  if (data.error) {
    return <div className="card"><div className="err">{data.reason || "Weather unavailable"}</div></div>;
  }

  const current = data.current || {};
  return (
    <div className="card">
      <div className="place">{data.timezone ? data.timezone.split("/").pop().replace(/_/g, " ") : "Current location"}</div>
      <div className="temp">{Math.round(current.temperature_2m)}<sup>°C</sup></div>
      <div className="desc">{describe(current.weathercode)}</div>
      <div className="meta">
        Feels {Math.round(current.apparent_temperature)}° · Humidity {current.relative_humidity_2m}% ·{" "}
        Wind {Math.round(current.wind_speed_10m)} km/h
      </div>
    </div>
  );
};

export const init = (dispatch) => {
  run(`
    curl -s '${ENDPOINT}?current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m&timezone=auto'
  `)
    .then((output) => dispatch({ type: "UB/COMMAND_RAN", output }))
    .catch((err) => dispatch({ type: "UB/COMMAND_RAN", error: String(err) }));
};
