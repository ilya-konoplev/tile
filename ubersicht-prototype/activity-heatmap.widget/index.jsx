import { React, run } from "uebersicht";

const { useState, useEffect, useRef } = React;

// Übersicht has no built-in way to move a widget – position is baked into the CSS
// above. So the card is draggable by its header and remembers where it was put.
const POSITION_FILE = "activity-heatmap.widget/position.json";

function loadPosition() {
  return run(`cat '${POSITION_FILE}' 2>/dev/null || true`).then((out) => {
    try {
      const p = JSON.parse(out);
      if (typeof p.x === "number" && typeof p.y === "number") return p;
    } catch (e) {
      /* no saved position yet */
    }
    return { x: 0, y: 0 };
  });
}

function savePosition(pos) {
  const x = Math.round(pos.x);
  const y = Math.round(pos.y);
  run(`printf '%s' '{"x":${x},"y":${y}}' > '${POSITION_FILE}'`);
}

// Path is relative to the widgets folder – keep the widget folder name in sync.
export const command = "python3 'activity-heatmap.widget/aggregate.py'";

export const refreshFrequency = 60 * 60 * 1000; // раз в час

const WEEKS = 13;
const FALLBACK_RAMP = ["#efecfe", "#d3c8ff", "#b29df8", "#8b73d2", "#624e9a"];

const INK = "rgba(20, 32, 28, 0.92)";
const INK_SOFT = "rgba(20, 32, 28, 0.55)";

// Colours are data-driven (they come from config.json via aggregate.py), so the
// palette lives in inline styles; only the static chrome is in className.
export const className = `
  top: 40px;
  left: 40px;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", sans-serif;
  -webkit-font-smoothing: antialiased;

  .ah-card {
    position: relative;
    display: inline-block;
    box-sizing: border-box;
    padding: 22px 24px 20px;
    border-radius: 26px;
    background: linear-gradient(
      135deg,
      rgba(255, 255, 255, 0.62) 0%,
      rgba(255, 255, 255, 0.34) 100%
    );
    backdrop-filter: blur(42px) saturate(180%);
    -webkit-backdrop-filter: blur(42px) saturate(180%);
    border: 1px solid rgba(255, 255, 255, 0.55);
    box-shadow:
      0 24px 60px rgba(30, 50, 60, 0.18),
      0 2px 8px rgba(30, 50, 60, 0.08),
      inset 0 1px 0 rgba(255, 255, 255, 0.85),
      inset 0 -1px 0 rgba(255, 255, 255, 0.25);
  }

  .ah-head {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 16px;
    margin-bottom: 18px;
  }

  .ah-title {
    font-size: 19px;
    font-weight: 700;
    letter-spacing: -0.4px;
    color: ${INK};
  }

  .ah-pill {
    font-size: 11px;
    font-weight: 600;
    color: ${INK_SOFT};
    background: rgba(255, 255, 255, 0.5);
    border: 1px solid rgba(255, 255, 255, 0.65);
    border-radius: 999px;
    padding: 4px 11px;
    box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.8);
  }

  .ah-handle { cursor: grab; user-select: none; -webkit-user-select: none; }
  .ah-handle.ah-dragging { cursor: grabbing; }

  .ah-grid { display: grid; grid-auto-flow: column; }

  .ah-cell {
    box-shadow:
      inset 0 1px 1px rgba(255, 255, 255, 0.45),
      inset 0 -1px 1px rgba(0, 0, 0, 0.06);
    transition: transform 0.15s ease, box-shadow 0.15s ease;
    cursor: default;
  }
  .ah-cell:hover {
    transform: scale(1.18);
    box-shadow:
      0 4px 12px var(--ah-glow),
      inset 0 1px 1px rgba(255, 255, 255, 0.5);
  }

  .ah-foot {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 18px;
    margin-top: 16px;
    font-size: 11px;
    font-weight: 600;
    color: ${INK_SOFT};
  }
  .ah-legend { display: flex; align-items: center; gap: 5px; font-weight: 500; }
  .ah-swatch {
    width: 11px;
    height: 11px;
    border-radius: 3.5px;
    box-shadow: inset 0 1px 1px rgba(255, 255, 255, 0.4);
  }

  .ah-tip {
    position: absolute;
    z-index: 10;
    min-width: 148px;
    padding: 9px 11px;
    border-radius: 12px;
    background: rgba(255, 255, 255, 0.82);
    backdrop-filter: blur(20px) saturate(180%);
    -webkit-backdrop-filter: blur(20px) saturate(180%);
    border: 1px solid rgba(255, 255, 255, 0.7);
    box-shadow: 0 10px 28px rgba(30, 50, 60, 0.18);
    font-size: 11px;
    line-height: 1.55;
    pointer-events: none;
    white-space: nowrap;
  }
  .ah-tip-date { color: ${INK_SOFT}; font-weight: 600; }
  .ah-tip-total { color: ${INK}; font-weight: 700; font-size: 13px; margin-bottom: 4px; }
  .ah-tip-row { display: flex; justify-content: space-between; gap: 14px; color: ${INK}; }
  .ah-tip-row span:last-child { color: ${INK_SOFT}; }

  .ah-msg { max-width: 250px; font-size: 12px; line-height: 1.55; color: ${INK}; white-space: normal; }
  .ah-msg b { font-weight: 700; }
`;

function plural(n, one, few, many) {
  const mod10 = n % 10;
  const mod100 = n % 100;
  if (mod10 === 1 && mod100 !== 11) return one;
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return few;
  return many;
}

function formatDuration(seconds) {
  const h = Math.floor(seconds / 3600);
  const m = Math.round((seconds % 3600) / 60);
  if (h === 0) return `${m} мин`;
  return m === 0 ? `${h} ч` : `${h} ч ${m} мин`;
}

function formatDate(iso) {
  const [y, m, d] = iso.split("-").map(Number);
  return new Date(y, m - 1, d).toLocaleDateString("ru-RU", {
    day: "numeric",
    month: "long",
  });
}

// GitHub-style grid: 13 columns of weeks, Monday-first, last column is this week.
function buildGrid() {
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const mondayOffset = (today.getDay() + 6) % 7;
  const start = new Date(today);
  start.setDate(start.getDate() - mondayOffset - (WEEKS - 1) * 7);

  const cells = [];
  for (let col = 0; col < WEEKS; col++) {
    for (let row = 0; row < 7; row++) {
      const date = new Date(start);
      date.setDate(date.getDate() + col * 7 + row);
      const iso = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(
        2,
        "0"
      )}-${String(date.getDate()).padStart(2, "0")}`;
      cells.push({ iso, row, col, future: date > today });
    }
  }
  return cells;
}

// Quartiles over the non-empty days, so the ramp adapts to how the mac is actually used.
function buildThresholds(days) {
  const totals = Object.values(days)
    .map((d) => d.t)
    .sort((a, b) => a - b);
  if (totals.length === 0) return [0, 0, 0];
  const at = (q) => totals[Math.min(totals.length - 1, Math.floor(totals.length * q))];
  return [at(0.25), at(0.5), at(0.75)];
}

function levelFor(total, thresholds) {
  if (!total) return 0;
  if (total <= thresholds[0]) return 1;
  if (total <= thresholds[1]) return 2;
  if (total <= thresholds[2]) return 3;
  return 4;
}

const Card = ({ children, style }) => (
  <div className="ah-card" style={style}>
    {children}
  </div>
);

const Message = ({ children }) => (
  <Card>
    <div className="ah-msg">{children}</div>
  </Card>
);

// Übersicht calls `render` as a plain function and hands the result to ReactDom.render,
// so hooks cannot live there – they belong in a real component like this one.
const Heatmap = ({ days, theme }) => {
  const [hover, setHover] = useState(null);
  const [pos, setPos] = useState({ x: 0, y: 0 });
  const [drag, setDrag] = useState(null);
  const posRef = useRef({ x: 0, y: 0 });
  const thresholds = buildThresholds(days);
  const cells = buildGrid();

  useEffect(() => {
    let alive = true;
    loadPosition().then((p) => {
      if (!alive) return;
      posRef.current = p;
      setPos(p);
    });
    return () => {
      alive = false;
    };
  }, []);

  useEffect(() => {
    if (!drag) return undefined;
    const move = (e) => {
      const next = {
        x: drag.ox + e.clientX - drag.sx,
        y: drag.oy + e.clientY - drag.sy,
      };
      posRef.current = next;
      setPos(next);
    };
    const up = () => {
      setDrag(null);
      savePosition(posRef.current);
    };
    window.addEventListener("mousemove", move);
    window.addEventListener("mouseup", up);
    return () => {
      window.removeEventListener("mousemove", move);
      window.removeEventListener("mouseup", up);
    };
  }, [drag]);

  const startDrag = (e) => {
    e.preventDefault();
    setHover(null);
    setDrag({ sx: e.clientX, sy: e.clientY, ox: pos.x, oy: pos.y });
  };

  const resetPosition = () => {
    const origin = { x: 0, y: 0 };
    posRef.current = origin;
    setPos(origin);
    savePosition(origin);
  };

  const ramp = theme.ramp && theme.ramp.length === 5 ? theme.ramp : FALLBACK_RAMP;
  const cell = theme.cellSize || 22;
  const gap = Math.max(3, Math.round(cell * 0.23));
  const radius = Math.max(3, Math.round(cell * 0.2));

  const tracked = cells.filter((c) => !c.future).length;
  const totalSeconds = cells.reduce(
    (sum, c) => sum + (days[c.iso] ? days[c.iso].t : 0),
    0
  );

  // Tooltip sits inside the card; flip it left/up near the edges so it never overflows.
  const tipStyle = hover
    ? {
        left: hover.col > WEEKS / 2 ? "auto" : hover.col * (cell + gap),
        right:
          hover.col > WEEKS / 2 ? (WEEKS - 1 - hover.col) * (cell + gap) : "auto",
        top: hover.row > 3 ? "auto" : hover.row * (cell + gap) + cell + 30,
        bottom: hover.row > 3 ? (6 - hover.row) * (cell + gap) + cell + 26 : "auto",
      }
    : null;

  return (
    <Card
      style={{
        "--ah-glow": `${ramp[4]}55`,
        transform: `translate(${pos.x}px, ${pos.y}px)`,
      }}
    >
      <div
        className={`ah-head ah-handle${drag ? " ah-dragging" : ""}`}
        onMouseDown={startDrag}
        onDoubleClick={resetPosition}
        title="Потяни, чтобы передвинуть · двойной клик – вернуть на место"
      >
        <div className="ah-title">Активность</div>
        <div className="ah-pill">
          {tracked} {plural(tracked, "день", "дня", "дней")}
        </div>
      </div>

      <div
        className="ah-grid"
        style={{
          gridTemplateRows: `repeat(7, ${cell}px)`,
          gridAutoColumns: `${cell}px`,
          gap: `${gap}px`,
        }}
      >
        {cells.map((c) => {
          const day = days[c.iso];
          const level = c.future ? 0 : levelFor(day && day.t, thresholds);
          return (
            <div
              key={c.iso}
              className="ah-cell"
              style={{
                borderRadius: `${radius}px`,
                background: ramp[level],
                opacity: c.future ? 0.35 : 1,
              }}
              onMouseEnter={() => !c.future && setHover({ ...c, day })}
              onMouseLeave={() => setHover(null)}
            />
          );
        })}
      </div>

      {theme.showLegend && (
        <div className="ah-foot">
          <div>{formatDuration(totalSeconds)} всего</div>
          <div className="ah-legend">
            <span>Меньше</span>
            {ramp.map((color, i) => (
              <span key={i} className="ah-swatch" style={{ background: color }} />
            ))}
            <span>Больше</span>
          </div>
        </div>
      )}

      {hover && (
        <div className="ah-tip" style={tipStyle}>
          <div className="ah-tip-date">{formatDate(hover.iso)}</div>
          <div className="ah-tip-total">
            {hover.day ? formatDuration(hover.day.t) : "нет активности"}
          </div>
          {hover.day &&
            hover.day.top.map(([name, seconds]) => (
              <div className="ah-tip-row" key={name}>
                <span>{name}</span>
                <span>{formatDuration(seconds)}</span>
              </div>
            ))}
        </div>
      )}
    </Card>
  );
};

export const render = ({ output, error }) => {
  if (error) return <Message>Ошибка запуска скрипта: {String(error)}</Message>;
  if (!output) return <Message>Считаю активность…</Message>;

  let data;
  try {
    data = JSON.parse(output);
  } catch (e) {
    return (
      <Message>Не удалось разобрать вывод скрипта: {String(output).slice(0, 200)}</Message>
    );
  }

  if (data.error === "no_access") {
    return (
      <Message>
        <b>Нет доступа к knowledgeC.db</b>
        <br />
        Дай <b>Full Disk Access</b> приложению Übersicht: System Settings → Privacy &amp;
        Security → Full Disk Access → добавь Übersicht и <b>полностью перезапусти</b> его.
      </Message>
    );
  }
  if (data.error) {
    return (
      <Message>
        <b>Сбой агрегации</b>
        <br />
        {data.detail}
      </Message>
    );
  }

  return <Heatmap days={data.days || {}} theme={data.theme || {}} />;
};
