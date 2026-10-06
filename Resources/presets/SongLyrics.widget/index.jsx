// Song Lyrics — live lyrics for whatever Music or Spotify is playing,
// fetched from lyrics.ovh. Falls back to a clean state when there are none.

export const command = `
enc() { printf '%s' "$1" | sed 's/%/%25/g; s/ /%20/g; s/#/%23/g; s/?/%3F/g; s|/|%2F|g; s/&/%26/g'; }
if pgrep -x Music >/dev/null 2>&1; then
  meta=$(osascript -e 'tell application "Music" to get name of current track & "|" & artist of current track & "|" & (player state as text)' 2>/dev/null) || { echo NEEDS_ACCESS; exit 0; }
elif pgrep -x Spotify >/dev/null 2>&1; then
  meta=$(osascript -e 'tell application "Spotify" to get name of current track & "|" & artist of current track & "|" & (player state as text)' 2>/dev/null) || { echo NEEDS_ACCESS; exit 0; }
else
  echo NO_PLAYER
  exit 0
fi
[ -z "$meta" ] && { echo NO_TRACK; exit 0; }
track=\${meta%%|*}
rest=\${meta#*|}
artist=\${rest%%|*}
state=\${rest#*|}
resp=$(curl -s --max-time 8 -w '\n%{http_code}' "https://api.lyrics.ovh/v1/$(enc "$artist")/$(enc "$track")")
code=$(printf '%s' "$resp" | tail -1)
if [ -z "$code" ] || [ "$code" = "000" ]; then
  echo NEEDS_NET
  exit 0
fi
if [ "$code" != "200" ]; then
  printf 'NOLYRICS|%s|%s|%s\n' "$track" "$artist" "$state"
  exit 0
fi
body=$(printf '%s' "$resp" | sed '$d')
plain=$(printf '%s' "$body" | tr '\n' ' ' | sed -n 's/.*"lyrics": *"\\([^"]*\\)".*/\\1/p')
if [ -z "$plain" ]; then
  printf 'NOLYRICS|%s|%s|%s\n' "$track" "$artist" "$state"
  exit 0
fi
printf 'LYRICS|%s|%s|%s\n' "$track" "$artist" "$state"
printf '%b' "$plain"
`;

export const refreshFrequency = 30000;

export const className = `
  position: fixed;
  left: 24px;
  bottom: 24px;
  width: 316px;
  box-sizing: border-box;
  padding: 14px 16px;
  background: rgba(18, 18, 22, 0.62);
  -webkit-backdrop-filter: blur(24px);
  border: 1px solid rgba(255, 255, 255, 0.14);
  border-radius: 16px;
  color: #f5f5f7;
  font-family: -apple-system, 'Helvetica Neue';
  font-size: 13px;

  .head {
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    opacity: 0.55;
    margin-bottom: 4px;
  }

  .track {
    font-weight: 600;
    font-size: 13px;
    margin-bottom: 8px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .line {
    line-height: 1.6;
    opacity: 0.9;
  }

  .line:first-child {
    opacity: 1;
    font-weight: 500;
  }

  .muted {
    opacity: 0.65;
    font-size: 12px;
    line-height: 1.45;
  }

  .paused {
    opacity: 0.55;
  }
`;

export const render = ({ output, error }) => {
  const head = (title, sub) => (
    <div>
      <div className="head">Lyrics</div>
      <div className="track">{title}</div>
      <div className="muted">{sub}</div>
    </div>
  );
  if (error) return head("Couldn't read the player.", String(error).slice(0, 120));
  const text = output || "";
  if (!text.trim()) return head("Lyrics", "Looking for what's playing…");
  const lines = String(text).split("\n");
  const [flag, track, artist, state] = (lines[0] || "").split("|");
  const title = track ? `${track} — ${artist}` : "Lyrics";
  if (flag === "NO_PLAYER")
    return head(title, "Open Music or Spotify and the words will show up here.");
  if (flag === "NEEDS_ACCESS")
    return head(title, "Needs Automation access — allow Wijeti in System Settings → Privacy & Security → Automation.");
  if (flag === "NO_TRACK") return head(title, "The player is open but has no track.");
  if (flag === "NEEDS_NET")
    return head(title, "Needs internet access — lyrics couldn't be fetched.");
  if (flag === "NOLYRICS") return head(title, "No lyrics found for this track.");
  const body = lines.slice(1).filter((l) => l.length > 0).slice(0, 12);
  return (
    <div className={state === "playing" ? "" : "paused"}>
      <div className="head">Lyrics · {state === "playing" ? "playing" : "paused"}</div>
      <div className="track">{title}</div>
      {body.map((line, i) => (
        <div className="line" key={i}>
          {line}
        </div>
      ))}
    </div>
  );
};
