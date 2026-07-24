import { Check, Search, X } from "lucide-react";
import { useMemo, useState } from "react";

export default function ItemPicker({ columns, selected, onConfirm, onClose }) {
  const [query, setQuery] = useState("");
  const [draft, setDraft] = useState(() => new Set(selected));
  const filtered = useMemo(() => {
    const normalized = query.trim().toLowerCase();
    if (!normalized) return columns;
    return columns.filter((column) => column.toLowerCase().includes(normalized));
  }, [columns, query]);

  function toggle(column) {
    setDraft((current) => {
      const next = new Set(current);
      if (next.has(column)) next.delete(column);
      else next.add(column);
      return next;
    });
  }

  return (
    <div className="modal-backdrop" role="presentation" onMouseDown={onClose}>
      <section
        className="item-picker"
        role="dialog"
        aria-modal="true"
        aria-labelledby="item-picker-title"
        onMouseDown={(event) => event.stopPropagation()}
      >
        <header>
          <div>
            <h3 id="item-picker-title">选择量表题项</h3>
            <p>已选择 {draft.size} 个变量</p>
          </div>
          <button className="icon-button" type="button" onClick={onClose} title="关闭">
            <X size={19} />
          </button>
        </header>
        <label className="search-box">
          <Search size={18} />
          <input
            autoFocus
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="搜索变量名或题目文字"
          />
        </label>
        <div className="picker-list">
          {filtered.map((column) => {
            const checked = draft.has(column);
            return (
              <button
                className={checked ? "picker-row selected" : "picker-row"}
                type="button"
                key={column}
                onClick={() => toggle(column)}
              >
                <span className="check-box">{checked ? <Check size={14} /> : null}</span>
                <span>{column}</span>
              </button>
            );
          })}
        </div>
        <footer>
          <button className="secondary-button" type="button" onClick={onClose}>取消</button>
          <button className="primary-button compact" type="button" onClick={() => onConfirm([...draft])}>
            确认题项
          </button>
        </footer>
      </section>
    </div>
  );
}
