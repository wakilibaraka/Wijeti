// Digital clock — big time, ticking seconds, full date.

export const command = `date "+%H:%M|%S|%A %d %B"`;

export const refreshFrequency = 1000;

export const className = `
  position: fixed;
  top: 6%;
  left: 0;
  right: 0;
  width: 420px;
  box-sizing: border-box;
  margin: auto;
  text-align: center;
  color: #f5f5f7;
  font-family: -apple-system, 'Helvetica Neue';
  text-shadow: 0 2px 18px rgba(0, 0, 0, 0.45);
  user-select: none;

  .time {
    font-size: 92px;
    font-weight: 200;
    letter-spacing: 0.02em;
    line-height: 1;
    font-variant-numeric: tabular-nums;
  }

  .seconds {
    font-size: 26px;
    font-weight: 300;
    opacity: 0.65;
    margin-left: 6px;
  }

  .date {
    margin-top: 8px;
    font-size: 15px;
    font-weight: 400;
    letter-spacing: 0.14em;
    text-transform: uppercase;
    opacity: 0.85;
  }
`;

const pad = (n) => (n < 10 ? `0${n}` : String(n));

export const render = ({ output }) => {
  let time, seconds, date;
  if (output) {
    const parts = String(output).trim().split("|");
    time = parts[0];
    seconds = parts[1];
    date = parts.slice(2).join(" ");
  } else {
    const now = new Date();
    time = `${pad(now.getHours())}:${pad(now.getMinutes())}`;
    seconds = pad(now.getSeconds());
    date = now.toLocaleDateString(undefined, {
      weekday: "long",
      day: "numeric",
      month: "long",
    });
  }
  return (
    <div>
      <div className="time">
        {time}
        <span className="seconds">{seconds}</span>
      </div>
      <div className="date">{date}</div>
    </div>
  );
};
