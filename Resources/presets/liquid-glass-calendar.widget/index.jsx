import { React, run } from "uebersicht";

export const refreshFrequency = 60000;
export const command = 'date "+%Y-%m-%d"';

export const className = `
  position: absolute;
  inset: 0;
  pointer-events: none;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  user-select: none;
  overflow: visible;

  .transparent-glass-card {
    position: absolute;
    pointer-events: auto;
    padding: 20px 24px;
    border-radius: 28px;
    background: rgba(10, 14, 24, 0.54);
    border: 1px solid rgba(255, 255, 255, 0.10);
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.16);
    color: #fff;
    display: flex;
    align-items: center;
    gap: 22px;
    box-sizing: border-box;
    cursor: grab;
    transform: translateZ(0);
    backface-visibility: hidden;
    contain: layout paint;
  }

  .transparent-glass-card:active {
    cursor: grabbing;
  }

  .date-display {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    justify-content: center;
    border-right: 1px solid rgba(255, 255, 255, 0.10);
    padding-right: 22px;
    min-width: 110px;
  }

  .day-name {
    font-size: 0.75rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1.8px;
    color: #ff5a4f;
    margin-bottom: -2px;
  }

  .huge-date {
    font-size: 4.8rem;
    font-weight: 300;
    letter-spacing: -2px;
    line-height: 0.95;
    color: rgba(255, 255, 255, 0.96);
  }

  .month-year {
    font-size: 0.9rem;
    font-weight: 500;
    color: rgba(255, 255, 255, 0.64);
    letter-spacing: 0.4px;
  }

  .calendar-grid {
    cursor: pointer;
  }

  table {
    border-collapse: separate;
    border-spacing: 3px 5px;
    table-layout: fixed;
  }

  td, th {
    text-align: center;
    width: 24px;
    height: 24px;
    border-radius: 7px;
  }

  thead tr th {
    font-size: 0.62rem;
    font-weight: 600;
    color: rgba(255, 255, 255, 0.55);
    text-transform: uppercase;
    letter-spacing: 0.8px;
    padding-bottom: 3px;
  }

  tbody td {
    font-size: 0.8rem;
    font-weight: 500;
    color: rgba(255, 255, 255, 0.9);
  }

  .dimmed {
    color: rgba(255, 255, 255, 0.24);
  }

  .today {
    font-weight: 700 !important;
    color: white !important;
    background: #ff5a4f;
  }

  .resize-handle {
    position: absolute;
    opacity: 0;
    pointer-events: auto;
    z-index: 2;
    transition: opacity 0.16s ease;
  }

  .resize-handle::before {
    content: "";
    position: absolute;
    inset: -4px;
    border-radius: 999px;
    background: rgba(255, 255, 255, 0.16);
    border: 1px solid rgba(255, 255, 255, 0.2);
    box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.08);
  }

  .transparent-glass-card.is-resizing .resize-handle,
  .resize-handle:hover {
    opacity: 1;
  }

  .resize-handle--n {
    top: -7px;
    left: 50%;
    width: 18px;
    height: 18px;
    transform: translateX(-50%);
    cursor: ns-resize;
  }

  .resize-handle--s {
    bottom: -7px;
    left: 50%;
    width: 18px;
    height: 18px;
    transform: translateX(-50%);
    cursor: ns-resize;
  }

  .resize-handle--e {
    top: 50%;
    right: -7px;
    width: 18px;
    height: 18px;
    transform: translateY(-50%);
    cursor: ew-resize;
  }

  .resize-handle--w {
    top: 50%;
    left: -7px;
    width: 18px;
    height: 18px;
    transform: translateY(-50%);
    cursor: ew-resize;
  }

  .resize-handle--ne {
    top: -7px;
    right: -7px;
    width: 18px;
    height: 18px;
    cursor: nesw-resize;
  }

  .resize-handle--nw {
    top: -7px;
    left: -7px;
    width: 18px;
    height: 18px;
    cursor: nwse-resize;
  }

  .resize-handle--se {
    bottom: -7px;
    right: -7px;
    width: 18px;
    height: 18px;
    cursor: nwse-resize;
  }

  .resize-handle--sw {
    bottom: -7px;
    left: -7px;
    width: 18px;
    height: 18px;
    cursor: nesw-resize;
  }
`;

const generateCalendarGrid = (currentDate) => {
  const year = currentDate.getFullYear();
  const month = currentDate.getMonth();
  const today = currentDate.getDate();

  const firstDayOfMonth = new Date(year, month, 1).getDay();
  const daysInMonth = new Date(year, month + 1, 0).getDate();
  const daysInPrevMonth = new Date(year, month, 0).getDate();

  const grid = [];
  let currentWeek = [];

  for (let i = 0; i < firstDayOfMonth; i++) {
    currentWeek.push({ day: daysInPrevMonth - firstDayOfMonth + i + 1, type: "dimmed" });
  }

  for (let i = 1; i <= daysInMonth; i++) {
    currentWeek.push({ day: i, type: i === today ? "today" : "active" });
    if (currentWeek.length === 7) {
      grid.push(currentWeek);
      currentWeek = [];
    }
  }

  let nextMonthDay = 1;
  while (currentWeek.length < 7 && currentWeek.length > 0) {
    currentWeek.push({ day: nextMonthDay++, type: "dimmed" });
  }
  if (currentWeek.length === 7) grid.push(currentWeek);

  while (grid.length < 6) {
    currentWeek = [];
    for (let i = 0; i < 7; i++) currentWeek.push({ day: nextMonthDay++, type: "dimmed" });
    grid.push(currentWeek);
  }

  return grid;
};

const readStoredValue = (key, fallback) => {
  if (typeof window === "undefined") return fallback;

  try {
    const saved = localStorage.getItem(key);
    return saved ? JSON.parse(saved) : fallback;
  } catch (error) {
    return fallback;
  }
};

const MIN_SIZE = { width: 320, height: 170 };

const InteractiveWidget = ({ error }) => {
  const [pos, setPos] = React.useState(() => readStoredValue("liquid_cal_pos", { x: 60, y: 60 }));
  const [size, setSize] = React.useState(() => {
    const saved = readStoredValue("liquid_cal_size", { width: 440, height: 180 });
    return {
      width: saved.width || MIN_SIZE.width,
      height: saved.height || MIN_SIZE.height,
    };
  });
  const [isResizing, setIsResizing] = React.useState(false);
  const [hoverEdge, setHoverEdge] = React.useState(null);
  const hoverTimeoutRef = React.useRef(null);

  React.useEffect(() => () => {
    if (hoverTimeoutRef.current) clearTimeout(hoverTimeoutRef.current);
  }, []);

  const handleDragStart = React.useCallback((event) => {
    if (event.target.closest(".calendar-grid") || event.target.closest(".resize-handle")) return;

    const startX = event.clientX - pos.x;
    const startY = event.clientY - pos.y;

    const onMouseMove = (moveEvent) => {
      setPos({ x: moveEvent.clientX - startX, y: moveEvent.clientY - startY });
    };

    const onMouseUp = () => {
      document.removeEventListener("mousemove", onMouseMove);
      document.removeEventListener("mouseup", onMouseUp);
      localStorage.setItem("liquid_cal_pos", JSON.stringify({ x: pos.x, y: pos.y }));
    };

    document.addEventListener("mousemove", onMouseMove);
    document.addEventListener("mouseup", onMouseUp);
  }, [pos.x, pos.y]);

  const clearHoverEdge = React.useCallback(() => {
    if (hoverTimeoutRef.current) {
      clearTimeout(hoverTimeoutRef.current);
      hoverTimeoutRef.current = null;
    }
    setHoverEdge(null);
  }, []);

  const handleMouseEnter = React.useCallback((event) => {
    const rect = event.currentTarget.getBoundingClientRect();
    const offsetX = event.clientX - rect.left;
    const offsetY = event.clientY - rect.top;
    const threshold = 12;

    let nextEdge = null;
    if (offsetX <= threshold) nextEdge = "w";
    else if (offsetX >= rect.width - threshold) nextEdge = "e";
    else if (offsetY <= threshold) nextEdge = "n";
    else if (offsetY >= rect.height - threshold) nextEdge = "s";

    if (nextEdge) {
      if (hoverTimeoutRef.current) clearTimeout(hoverTimeoutRef.current);
      hoverTimeoutRef.current = setTimeout(() => setHoverEdge(nextEdge), 140);
    } else {
      clearHoverEdge();
    }
  }, [clearHoverEdge]);

  const handleMouseMove = React.useCallback((event) => {
    const rect = event.currentTarget.getBoundingClientRect();
    const offsetX = event.clientX - rect.left;
    const offsetY = event.clientY - rect.top;
    const threshold = 12;

    let nextEdge = null;
    if (offsetX <= threshold) nextEdge = "w";
    else if (offsetX >= rect.width - threshold) nextEdge = "e";
    else if (offsetY <= threshold) nextEdge = "n";
    else if (offsetY >= rect.height - threshold) nextEdge = "s";

    if (nextEdge) {
      if (hoverTimeoutRef.current) clearTimeout(hoverTimeoutRef.current);
      hoverTimeoutRef.current = setTimeout(() => setHoverEdge(nextEdge), 140);
    } else {
      clearHoverEdge();
    }
  }, [clearHoverEdge]);

  const handleResizeStart = React.useCallback((event, direction) => {
    event.preventDefault();
    event.stopPropagation();

    setIsResizing(true);

    const startX = event.clientX;
    const startY = event.clientY;
    const startWidth = size.width;
    const startHeight = size.height;
    const startLeft = pos.x;
    const startTop = pos.y;

    const cursorMap = {
      n: "ns-resize",
      s: "ns-resize",
      e: "ew-resize",
      w: "ew-resize",
      ne: "nesw-resize",
      nw: "nwse-resize",
      se: "nwse-resize",
      sw: "nesw-resize",
    };

    document.body.style.cursor = cursorMap[direction];

    let nextWidth = startWidth;
    let nextHeight = startHeight;
    let nextLeft = startLeft;
    let nextTop = startTop;

    const onMouseMove = (moveEvent) => {
      const deltaX = moveEvent.clientX - startX;
      const deltaY = moveEvent.clientY - startY;

      if (direction.includes("e")) {
        nextWidth = Math.max(MIN_SIZE.width, startWidth + deltaX);
      }

      if (direction.includes("w")) {
        const proposedWidth = Math.max(MIN_SIZE.width, startWidth - deltaX);
        nextWidth = proposedWidth;
        nextLeft = startLeft + (startWidth - proposedWidth);
      }

      if (direction.includes("s")) {
        nextHeight = Math.max(MIN_SIZE.height, startHeight + deltaY);
      }

      if (direction.includes("n")) {
        const proposedHeight = Math.max(MIN_SIZE.height, startHeight - deltaY);
        nextHeight = proposedHeight;
        nextTop = startTop + (startHeight - proposedHeight);
      }

      setSize({ width: nextWidth, height: nextHeight });
      setPos({ x: nextLeft, y: nextTop });
    };

    const onMouseUp = () => {
      document.removeEventListener("mousemove", onMouseMove);
      document.removeEventListener("mouseup", onMouseUp);
      document.body.style.cursor = "";
      setIsResizing(false);
      localStorage.setItem("liquid_cal_size", JSON.stringify({ width: nextWidth, height: nextHeight }));
      localStorage.setItem("liquid_cal_pos", JSON.stringify({ x: nextLeft, y: nextTop }));
    };

    document.addEventListener("mousemove", onMouseMove);
    document.addEventListener("mouseup", onMouseUp);
  }, [pos.x, pos.y, size.width, size.height]);

  const now = new Date();
  const dayName = now.toLocaleDateString("en-US", { weekday: "long" });
  const monthYear = now.toLocaleDateString("en-US", { month: "long", year: "numeric" });
  const dateNum = now.getDate();
  const daysOfWeek = ["S", "M", "T", "W", "T", "F", "S"];
  const calendarGrid = generateCalendarGrid(now);

  return (
    <div
      className={`transparent-glass-card${isResizing ? " is-resizing" : ""}`}
      onMouseDown={handleDragStart}
      onMouseEnter={handleMouseEnter}
      onMouseMove={handleMouseMove}
      onMouseLeave={clearHoverEdge}
      style={{ left: pos.x, top: pos.y, width: size.width, height: size.height }}
    >
      {error ? (
        <div style={{ color: "#ff6b6b", pointerEvents: "auto", padding: "20px" }}>Error loading data.</div>
      ) : (
        <>
          <div className="date-display">
            <div className="day-name">{dayName}</div>
            <div className="huge-date">{dateNum}</div>
            <div className="month-year">{monthYear}</div>
          </div>

          <div className="calendar-grid" onClick={() => run("open -a Calendar")}>
            <table>
              <thead>
                <tr>
                  {daysOfWeek.map((day, index) => <th key={index}>{day}</th>)}
                </tr>
              </thead>
              <tbody>
                {calendarGrid.map((row, rowIndex) => (
                  <tr key={rowIndex}>
                    {row.map((cell, cellIndex) => (
                      <td key={cellIndex} className={cell.type}>
                        {cell.day}
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <div className={`resize-handle resize-handle--n${hoverEdge === "n" ? " visible" : ""}`} onMouseDown={(event) => handleResizeStart(event, "n")} />
          <div className={`resize-handle resize-handle--s${hoverEdge === "s" ? " visible" : ""}`} onMouseDown={(event) => handleResizeStart(event, "s")} />
          <div className={`resize-handle resize-handle--e${hoverEdge === "e" ? " visible" : ""}`} onMouseDown={(event) => handleResizeStart(event, "e")} />
          <div className={`resize-handle resize-handle--w${hoverEdge === "w" ? " visible" : ""}`} onMouseDown={(event) => handleResizeStart(event, "w")} />
          <div className={`resize-handle resize-handle--ne${hoverEdge === "n" || hoverEdge === "e" ? " visible" : ""}`} onMouseDown={(event) => handleResizeStart(event, "ne")} />
          <div className={`resize-handle resize-handle--nw${hoverEdge === "n" || hoverEdge === "w" ? " visible" : ""}`} onMouseDown={(event) => handleResizeStart(event, "nw")} />
          <div className={`resize-handle resize-handle--se${hoverEdge === "s" || hoverEdge === "e" ? " visible" : ""}`} onMouseDown={(event) => handleResizeStart(event, "se")} />
          <div className={`resize-handle resize-handle--sw${hoverEdge === "s" || hoverEdge === "w" ? " visible" : ""}`} onMouseDown={(event) => handleResizeStart(event, "sw")} />
        </>
      )}
    </div>
  );
};

export const render = ({ error }) => <InteractiveWidget error={error} />;
