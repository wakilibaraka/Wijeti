// Weather — current conditions plus a 3-day outlook from Open-Meteo.
// Uses the location set in Wijeti's Preferences → Data sources.

export const command = `
lat=$(defaults read com.wijeti.Wijeti dataSource.openMeteo.latitude 2>/dev/null || defaults read WijetiApp dataSource.openMeteo.latitude 2>/dev/null || true)
lon=$(defaults read com.wijeti.Wijeti dataSource.openMeteo.longitude 2>/dev/null || defaults read WijetiApp dataSource.openMeteo.longitude 2>/dev/null || true)
city=$(defaults read com.wijeti.Wijeti dataSource.openMeteo.city 2>/dev/null || defaults read WijetiApp dataSource.openMeteo.city 2>/dev/null || true)
u=$(defaults read com.wijeti.Wijeti dataSource.units 2>/dev/null || defaults read WijetiApp dataSource.units 2>/dev/null || echo metric)
if [ -z "$lat" ] || [ -z "$lon" ]; then
  echo NEEDS_LOCATION
  exit 0
fi
qp="temperature_unit=celsius&wind_speed_unit=kmh"
[ "$u" = "imperial" ] && qp="temperature_unit=fahrenheit&wind_speed_unit=mph"
json=$(curl -s --max-time 8 "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current=temperature_2m,weather_code,wind_speed_10m&daily=weather_code,temperature_2m_max,temperature_2m_min&forecast_days=4&timezone=auto&$qp")
if [ -z "$json" ]; then
  echo NEEDS_NET
  exit 0
fi
printf '%s\n%s' "$city" "$json"
`;

export const refreshFrequency = 600000;

export const className = `
  position: fixed;
  left: 24px;
  top: 50%;
  transform: translateY(-50%);
  width: 244px;
  box-sizing: border-box;
  padding: 14px 16px;
  background: rgba(18, 18, 22, 0.62);
  -webkit-backdrop-filter: blur(24px);
  border: 1px solid rgba(255, 255, 255, 0.14);
  border-radius: 16px;
  color: #f5f5f7;
  font-family: -apple-system, 'Helvetica Neue';
  font-size: 13px;

  .city {
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    opacity: 0.55;
  }

  .now {
    display: flex;
    align-items: baseline;
    gap: 8px;
    margin: 6px 0 2px;
  }

  .temp {
    font-size: 44px;
    font-weight: 200;
    line-height: 1;
    font-variant-numeric: tabular-nums;
  }

  .cond {
    font-size: 12px;
    opacity: 0.8;
    margin-bottom: 12px;
  }

  .days {
    display: flex;
    justify-content: space-between;
    border-top: 1px solid rgba(255, 255, 255, 0.12);
    padding-top: 10px;
  }

  .day {
    text-align: center;
    font-size: 11px;
  }

  .day b {
    display: block;
    font-weight: 500;
    margin-top: 3px;
    font-variant-numeric: tabular-nums;
  }

  .day small {
    opacity: 0.55;
    font-size: 10px;
  }

  .needs {
    padding: 6px 0;
  }

  .needs .icon {
    font-size: 22px;
    margin-bottom: 6px;
  }

  .needs .head {
    font-weight: 600;
    font-size: 13px;
    margin-bottom: 4px;
  }

  .needs .sub {
    font-size: 12px;
    opacity: 0.7;
    line-height: 1.4;
  }
`;

const WMO = (code) => {
  if (code === 0) return ["Clear", "☀️"];
  if (code === 1) return ["Mostly clear", "🌤"];
  if (code === 2) return ["Partly cloudy", "⛅️"];
  if (code === 3) return ["Overcast", "☁️"];
  if (code === 45 || code === 48) return ["Fog", "🌫"];
  if (code >= 51 && code <= 57) return ["Drizzle", "🌦"];
  if (code >= 61 && code <= 67) return ["Rain", "🌧"];
  if (code >= 71 && code <= 77) return ["Snow", "❄️"];
  if (code >= 80 && code <= 82) return ["Showers", "🌦"];
  if (code === 85 || code === 86) return ["Snow showers", "🌨"];
  if (code >= 95) return ["Thunderstorm", "⛈"];
  return ["Unknown", "·"];
};

const needs = (icon, head, sub) => (
  <div className="needs">
    <div className="icon">{icon}</div>
    <div className="head">{head}</div>
    <div className="sub">{sub}</div>
  </div>
);

export const render = ({ output, error }) => {
  if (error) return needs("📡", "Couldn't reach the weather service.", "Check your connection — it will retry shortly.");
  if (!output) return needs("🌤", "Loading weather…", "One moment.");
  const text = String(output).trim();
  if (text === "NEEDS_LOCATION")
    return needs("📍", "Set your location", "Open Preferences → Data sources and turn on Use My Location.");
  if (text.startsWith("NEEDS_NET"))
    return needs("📡", "Needs internet access", "The weather service couldn't be reached.");

  const nl = text.indexOf("\n");
  if (nl < 0) return needs("📡", "Needs internet access", "The weather service returned nothing.");
  const city = text.slice(0, nl).trim() || "Current location";
  let data;
  try {
    data = JSON.parse(text.slice(nl + 1));
  } catch (e) {
    return needs("📡", "Needs internet access", "The weather service returned something unexpected.");
  }
  if (!data || !data.current) return needs("📡", "Needs internet access", "No current conditions were returned.");

  const unit = (data.current_units && data.current_units.temperature_2m) || "°";
  const [condLabel, condEmoji] = WMO(data.current.weather_code);
  const days = (data.daily && data.daily.time) || [];
  const codes = (data.daily && data.daily.weather_code) || [];
  const maxes = (data.daily && data.daily.temperature_2m_max) || [];
  const mins = (data.daily && data.daily.temperature_2m_min) || [];
  const weekday = (t) => {
    try {
      return new Date(`${t}T00:00:00`).toLocaleDateString(undefined, { weekday: "short" });
    } catch (e) {
      return "";
    }
  };
  return (
    <div>
      <div className="city">{city}</div>
      <div className="now">
        <span className="temp">
          {Math.round(data.current.temperature_2m)}
          {unit}
        </span>
        <span>{condEmoji}</span>
      </div>
      <div className="cond">
        {condLabel} · wind {Math.round(data.current.wind_speed_10m)}
        {unit === "°F" ? " mph" : " km/h"}
      </div>
      <div className="days">
        {days.slice(0, 4).map((day, i) => (
          <div className="day" key={day}>
            {i === 0 ? "Today" : weekday(day)}
            <b>
              {WMO(codes[i])[1]} {Math.round(maxes[i])}°
            </b>
            <small>{Math.round(mins[i])}°</small>
          </div>
        ))}
      </div>
    </div>
  );
};
