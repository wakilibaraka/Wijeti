// Now Playing — the current track from Music or Spotify.

export const command = `
if pgrep -x Music >/dev/null 2>&1; then
  out=$(osascript -e 'tell application "Music" to get name of current track & "|" & artist of current track & "|" & (player state as text)' 2>/dev/null) || { echo NEEDS_ACCESS; exit 0; }
  [ -z "$out" ] && { echo NO_TRACK; exit 0; }
  echo "Music|$out"
elif pgrep -x Spotify >/dev/null 2>&1; then
  out=$(osascript -e 'tell application "Spotify" to get name of current track & "|" & artist of current track & "|" & (player state as text)' 2>/dev/null) || { echo NEEDS_ACCESS; exit 0; }
  [ -z "$out" ] && { echo NO_TRACK; exit 0; }
  echo "Spotify|$out"
else
  echo NO_PLAYER
fi
`;

export const refreshFrequency = 5000;

export const className = `
  position: fixed;
  bottom: 24px;
  left: 0;
  right: 0;
  width: 320px;
  box-sizing: border-box;
  margin: auto;
  padding: 13px 16px;
  background: rgba(18, 18, 22, 0.62);
  -webkit-backdrop-filter: blur(24px);
  border: 1px solid rgba(255, 255, 255, 0.14);
  border-radius: 16px;
  color: #f5f5f7;
  font-family: -apple-system, 'Helvetica Neue';
  font-size: 13px;

  .head {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    opacity: 0.55;
    margin-bottom: 6px;
  }

  .dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: #30d158;
  }

  .dot.paused {
    background: #ffd60a;
  }

  .track {
    font-weight: 600;
    font-size: 14px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .artist {
    opacity: 0.7;
    font-size: 12px;
    margin-top: 2px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .muted {
    opacity: 0.65;
    font-size: 12px;
    line-height: 1.45;
  }

  .head-np {
    font-weight: 600;
    font-size: 13px;
    margin-bottom: 3px;
  }
`;

export const render = ({ output, error }) => {
  if (error) {
    return (
      <div>
        <div className="head">Now playing</div>
        <div className="muted">Couldn't read the player.</div>
      </div>
    );
  }
  const text = (output || "").trim();
  if (!text) {
    return (
      <div>
        <div className="head">Now playing</div>
        <div className="muted">Checking…</div>
      </div>
    );
  }
  if (text === "NO_PLAYER") {
    return (
      <div>
        <div className="head">Now playing</div>
        <div className="head-np">Nothing playing</div>
        <div className="muted">Open Music or Spotify and this will light up.</div>
      </div>
    );
  }
  if (text === "NEEDS_ACCESS") {
    return (
      <div>
        <div className="head">Now playing</div>
        <div className="head-np">Needs Automation access</div>
        <div className="muted">
          System Settings → Privacy &amp; Security → Automation → let Wijeti control Music or
          Spotify.
        </div>
      </div>
    );
  }
  if (text === "NO_TRACK") {
    return (
      <div>
        <div className="head">Now playing</div>
        <div className="head-np">Nothing loaded</div>
        <div className="muted">The player is open but has no track.</div>
      </div>
    );
  }
  const parts = text.split("|");
  const player = parts[0];
  const state = parts[parts.length - 1];
  const track = parts[1] || "?";
  const artist = parts.length > 3 ? parts.slice(2, parts.length - 1).join("|") : parts[2] || "";
  const playing = state === "playing";
  return (
    <div>
      <div className="head">
        <span className={`dot${playing ? "" : " paused"}`} />
        {player} · {state}
      </div>
      <div className="track">{playing ? "▶ " : "❚❚ "}
        {track}
      </div>
      <div className="artist">{artist}</div>
    </div>
  );
};
