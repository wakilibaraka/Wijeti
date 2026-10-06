// Quote of the Day — a new quote every day, rotating offline (no network).

export const command = `date +%j`;

export const refreshFrequency = 3600000;

export const className = `
  position: fixed;
  top: 16%;
  left: 0;
  right: 0;
  width: 400px;
  box-sizing: border-box;
  margin: auto;
  padding: 18px 22px;
  text-align: center;
  background: rgba(18, 18, 22, 0.55);
  -webkit-backdrop-filter: blur(24px);
  border: 1px solid rgba(255, 255, 255, 0.14);
  border-radius: 16px;
  color: #f5f5f7;
  font-family: -apple-system, 'Helvetica Neue';

  .quote {
    font-size: 17px;
    font-weight: 300;
    line-height: 1.5;
    font-style: italic;
  }

  .quote::before {
    content: '\\201C';
    opacity: 0.4;
  }

  .quote::after {
    content: '\\201D';
    opacity: 0.4;
  }

  .author {
    margin-top: 8px;
    font-size: 12px;
    letter-spacing: 0.1em;
    text-transform: uppercase;
    opacity: 0.6;
  }
`;

const quotes = [
  ["The only way to do great work is to love what you do.", "Steve Jobs"],
  ["Simplicity is the ultimate sophistication.", "Leonardo da Vinci"],
  ["Well done is better than well said.", "Benjamin Franklin"],
  ["It always seems impossible until it's done.", "Nelson Mandela"],
  ["What we do in life echoes in eternity.", "Marcus Aurelius"],
  ["The best way out is always through.", "Robert Frost"],
  ["Stay hungry, stay foolish.", "The Whole Earth Catalog"],
  ["Make it simple, but significant.", "Don Draper"],
  ["Everything you can imagine is real.", "Pablo Picasso"],
  ["Doubt kills more dreams than failure ever will.", "Suzy Kassem"],
  ["Little by little, one travels far.", "J.R.R. Tolkien"],
  ["The secret of getting ahead is getting started.", "Mark Twain"],
  ["Energy and persistence conquer all things.", "Benjamin Franklin"],
  ["If you're going through hell, keep going.", "Winston Churchill"],
  ["Dream big and dare to fail.", "Norman Vaughan"],
  ["Done is better than perfect.", "Sheryl Sandberg"],
];

export const render = ({ output }) => {
  const day = (parseInt(output, 10) || 1) - 1;
  const [quote, author] = quotes[((day % quotes.length) + quotes.length) % quotes.length];
  return (
    <div>
      <div className="quote">{quote}</div>
      <div className="author">{author}</div>
    </div>
  );
};
