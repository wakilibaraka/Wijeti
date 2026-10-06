// Wijeti's welcome widget — adapt it as you see fit, or delete it once you
// have made your own. Full docs: https://github.com/felixhageloh/uebersicht

// the shell command that gets executed every time this widget refreshes
export const command = "whoami";

// the refresh frequency in milliseconds
export const refreshFrequency = 1000000;

// the CSS style for this widget, written using Emotion
// https://emotion.sh/
export const className = `
  top: 10%;
  right: 0;
  left: 0;
  width: 340px;
  box-sizing: border-box;
  margin: auto;
  padding: 20px;
  background-color: rgba(255, 255, 255, 0.92);
  -webkit-backdrop-filter: blur(20px);
  color: #141f33;
  font-family: -apple-system, 'Helvetica Neue';
  font-weight: 300;
  border: 2px solid #fff;
  border-radius: 6px;
  text-align: justify;
  line-height: 1.5;

  h1 {
    font-size: 20px;
    margin: 0 0 8px;
  }

  em {
    font-weight: 400;
    font-style: normal;
  }
`;

// render gets called after the shell command has executed. The command's
// output is passed in as a string.
export const render = ({ output }) => (
  <div>
    <h1>Hi, {output || "there"}</h1>
    <p>
      Thanks for trying out Wijeti!
      This is an example widget to get you started.
    </p>
    <p>
      Widgets sit on your desktop behind everything else. Click the tray icon
      for <em>Refresh Widgets</em>, <em>Widget Library</em>, or{" "}
      <em>Preferences</em>.
    </p>
    <p>
      To add your own, drop a widget folder anywhere on this window — or edit
      this file: choose <em>Open Widgets Folder</em> from the tray menu.
    </p>
  </div>
);
