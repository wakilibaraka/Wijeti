// Disk & load — root disk usage plus 1/5/15-minute load averages.

export const command = `
d=$(df -k / | awk 'NR==2 {u=int($3*100/($3+$4)); g=int($4/1024/1024); print u"|"g}')
l=$(sysctl -n vm.loadavg | awk '{printf "%s|%s|%s", $2, $3, $4}')
echo "$d|$l"
`;

export const refreshFrequency = 30000;

export const className = `
  position: fixed;
  top: 24px;
  left: 24px;
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
    margin-bottom: 10px;
  }

  .fill {
    height: 100%;
    border-radius: 3px;
    background: hsl(205, 75%, 60%);
  }

  .loads {
    display: flex;
    justify-content: space-between;
    font-variant-numeric: tabular-nums;
  }

  .loads span {
    text-align: center;
  }

  .loads small {
    display: block;
    opacity: 0.5;
    font-size: 10px;
    margin-top: 2px;
  }

  .muted {
    opacity: 0.6;
    font-size: 12px;
  }
`;

export const render = ({ output, error }) => {
  if (error || !output) {
    return (
      <div>
        <div className="title">Disk &amp; Load</div>
        <div className="muted">{error ? "Couldn't read disk stats." : "Reading…"}</div>
      </div>
    );
  }
  const [used, free, l1, l5, l15] = String(output).trim().split("|");
  if (used === undefined || l1 === undefined) {
    return (
      <div>
        <div className="title">Disk &amp; Load</div>
        <div className="muted">Couldn't read disk stats.</div>
      </div>
    );
  }
  return (
    <div>
      <div className="title">Disk &amp; Load</div>
      <div className="label">
        <span>Macintosh HD</span>
        <span className="value">{used}%</span>
      </div>
      <div className="track">
        <div className="fill" style={{ width: `${parseInt(used, 10) || 0}%` }} />
      </div>
      <div className="label">
        <span>Free</span>
        <span className="value">{free} GB</span>
      </div>
      <div className="loads">
        <span>
          {l1}
          <small>1 min</small>
        </span>
        <span>
          {l5}
          <small>5 min</small>
        </span>
        <span>
          {l15}
          <small>15 min</small>
        </span>
      </div>
    </div>
  );
};
