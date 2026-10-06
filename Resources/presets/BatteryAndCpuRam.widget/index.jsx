// Battery, CPU & RAM — one glance at how the machine is doing.

export const command = `
bat=$(pmset -g batt | awk 'NR==2 {gsub(/[%;]/,"",$3); gsub(";","",$4); print $3"|"$4}')
[ -z "$bat" ] && bat="NOBAT|NOBAT"
cpu=$(top -l 1 -n 0 | awk '/CPU usage/{print int($3)+int($5)}')
p=$(sysctl -n hw.pagesize)
t=$(( $(sysctl -n hw.memsize) / p ))
u=$(vm_stat | awk '/Pages active/{a=$3} /Pages wired down/{w=$4} /Pages occupied by compressor/{c=$5} END{gsub(/\\./,"",a);gsub(/\\./,"",w);gsub(/\\./,"",c);print a+w+c}')
mem=$(( u * 100 / t ))
echo "$bat|$cpu|$mem"
`;

export const refreshFrequency = 5000;

export const className = `
  position: fixed;
  top: 24px;
  right: 24px;
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
  letter-spacing: 0.01em;

  .title {
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    opacity: 0.55;
    margin-bottom: 10px;
  }

  .row {
    margin-bottom: 10px;
  }

  .row:last-child {
    margin-bottom: 0;
  }

  .label {
    display: flex;
    justify-content: space-between;
    margin-bottom: 4px;
  }

  .value {
    font-variant-numeric: tabular-nums;
    font-weight: 500;
  }

  .track {
    height: 5px;
    background: rgba(255, 255, 255, 0.16);
    border-radius: 3px;
    overflow: hidden;
  }

  .fill {
    height: 100%;
    border-radius: 3px;
  }

  .muted {
    opacity: 0.6;
    font-size: 12px;
  }
`;

const barColor = (pct, hue) =>
  pct > 60 ? `hsl(${hue}, 75%, 60%)` : pct > 30 ? `hsl(38, 90%, 58%)` : `hsl(0, 80%, 62%)`;

const Row = ({ label, value, pct, hue }) => (
  <div className="row">
    <div className="label">
      <span>{label}</span>
      <span className="value">{value}</span>
    </div>
    <div className="track">
      <div
        className="fill"
        style={{ width: `${Math.max(0, Math.min(100, pct))}%`, background: barColor(pct, hue) }}
      />
    </div>
  </div>
);

export const render = ({ output, error }) => {
  if (error || !output) {
    return (
      <div>
        <div className="title">System</div>
        <div className="muted">{error ? "Couldn't read system stats." : "Reading…"}</div>
      </div>
    );
  }
  const [bat, batState, cpu, mem] = String(output).trim().split("|");
  if (cpu === undefined || mem === undefined || cpu === "" || mem === "") {
    return (
      <div>
        <div className="title">System</div>
        <div className="muted">Couldn't read system stats.</div>
      </div>
    );
  }
  const batteryLabel =
    batState === "discharging"
      ? "on battery"
      : batState === "charging"
        ? "charging"
        : "charged";
  const batteryRow =
    bat !== "NOBAT"
      ? Row({
          label: `Battery · ${batteryLabel}`,
          value: `${bat}%`,
          pct: parseInt(bat, 10) || 0,
          hue: 145,
        })
      : null;
  return (
    <div>
      <div className="title">System</div>
      {batteryRow}
      {Row({ label: "CPU", value: `${cpu}%`, pct: parseInt(cpu, 10) || 0, hue: 205 })}
      {Row({ label: "Memory", value: `${mem}%`, pct: parseInt(mem, 10) || 0, hue: 265 })}
    </div>
  );
};
