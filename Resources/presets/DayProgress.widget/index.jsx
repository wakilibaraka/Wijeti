// Day & Week Progress — how far through the workday (9–17) and the week you are.

export const command = `date "+%H:%M|%u"`;

export const refreshFrequency = 60000;

export const className = `
  position: fixed;
  right: 24px;
  top: 50%;
  transform: translateY(-50%);
  width: 236px;
  box-sizing: border-box;
  padding: 14px 16px;
  background: rgba(18, 18, 22, 0.62);
  -webkit-backdrop-filter: blur(24px);
  border: 1px solid rgba(255, 255, 255, 0.14);
  border-radius: 16px;
  color: #f5f5f7;
  font-family: -apple-system, 'Helvetica Neue';
  font-size: 13px;

  .time {
    font-size: 34px;
    font-weight: 200;
    line-height: 1;
    font-variant-numeric: tabular-nums;
    margin-bottom: 12px;
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
    font-size: 12px;
  }

  .value {
    font-variant-numeric: tabular-nums;
    opacity: 0.8;
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
    background: hsl(145, 65%, 55%);
    transition: width 0.6s;
  }

  .fill.week {
    background: hsl(265, 65%, 62%);
  }

  .note {
    font-size: 11px;
    opacity: 0.55;
    margin-top: 8px;
  }
`;

const pad = (n) => (n < 10 ? `0${n}` : String(n));
const clamp = (n) => Math.max(0, Math.min(100, n));

export const render = ({ output }) => {
  let time, dayOfWeek, minutes;
  if (output) {
    const [hm, dow] = String(output).trim().split("|");
    time = hm;
    dayOfWeek = parseInt(dow, 10) || 1;
    const [h, m] = hm.split(":").map((n) => parseInt(n, 10) || 0);
    minutes = h * 60 + m;
  } else {
    const now = new Date();
    time = `${pad(now.getHours())}:${pad(now.getMinutes())}`;
    dayOfWeek = now.getDay() === 0 ? 7 : now.getDay();
    minutes = now.getHours() * 60 + now.getMinutes();
  }

  const weekend = dayOfWeek >= 6;
  // Workday: 09:00 (540) to 17:00 (1020).
  const rawWork = ((minutes - 540) / 480) * 100;
  const workPct = weekend ? 0 : clamp(rawWork);
  const workNote = weekend
    ? "It's the weekend 🎉"
    : minutes < 540
      ? "Starts at 9:00"
      : minutes >= 1020
        ? "Done for the day"
        : "Through the workday";
  const weekPct = clamp(((dayOfWeek - 1) * 1440 + minutes) / (7 * 1440) * 100);

  return (
    <div>
      <div className="time">{time}</div>
      <div className="row">
        <div className="label">
          <span>Workday</span>
          <span className="value">{Math.round(workPct)}%</span>
        </div>
        <div className="track">
          <div className="fill" style={{ width: `${workPct}%` }} />
        </div>
      </div>
      <div className="row">
        <div className="label">
          <span>Week</span>
          <span className="value">{Math.round(weekPct)}%</span>
        </div>
        <div className="track">
          <div className="fill week" style={{ width: `${weekPct}%` }} />
        </div>
      </div>
      <div className="note">{workNote}</div>
    </div>
  );
};
