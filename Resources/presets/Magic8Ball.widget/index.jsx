// Magic 8-Ball — click the ball to ask your question. Fully offline.

export const className = `
  position: fixed;
  top: 50%;
  left: 50%;
  transform: translate(-50%, -50%);
  width: 188px;
  height: 188px;
  box-sizing: border-box;
  border-radius: 50%;
  display: flex;
  align-items: center;
  justify-content: center;
  text-align: center;
  padding: 24px;
  cursor: pointer;
  user-select: none;
  color: #f5f5f7;
  font-family: -apple-system, 'Helvetica Neue';
  font-size: 15px;
  font-weight: 500;
  line-height: 1.35;
  background: radial-gradient(circle at 32% 28%, #3a3a44 0%, #17171c 55%, #0a0a0e 100%);
  border: 1px solid rgba(255, 255, 255, 0.18);
  box-shadow: 0 12px 40px rgba(0, 0, 0, 0.5), inset 0 1px 8px rgba(255, 255, 255, 0.12);
  text-shadow: 0 1px 6px rgba(0, 0, 0, 0.6);

  .hint {
    font-size: 12px;
    font-weight: 400;
    opacity: 0.55;
    margin-top: 6px;
    display: block;
  }
`;

const answers = [
  "It is certain.",
  "It is decidedly so.",
  "Without a doubt.",
  "Yes — definitely.",
  "You may rely on it.",
  "As I see it, yes.",
  "Most likely.",
  "Outlook good.",
  "Yes.",
  "Signs point to yes.",
  "Reply hazy, try again.",
  "Ask again later.",
  "Better not tell you now.",
  "Cannot predict now.",
  "Concentrate and ask again.",
  "Don't count on it.",
  "My reply is no.",
  "My sources say no.",
  "Outlook not so good.",
  "Very doubtful.",
];

export const initialState = { pick: -1, asks: 0 };

export const updateState = (event, previous) => {
  if (event && event.type === "ROLL") {
    return {
      pick: Math.floor(Math.random() * answers.length),
      asks: (previous.asks || 0) + 1,
    };
  }
  return previous;
};

export const render = ({ pick, asks }, dispatch) => (
  <div
    onClick={() => dispatch({ type: "ROLL" })}
    title="Click to ask"
    style={asks > 0 ? { transition: "transform 0.15s" } : undefined}
  >
    <div>
      {pick < 0 ? (
        <span>
          🎱
          <span className="hint">ask me anything</span>
        </span>
      ) : (
        <span>{answers[pick]}</span>
      )}
    </div>
  </div>
);
