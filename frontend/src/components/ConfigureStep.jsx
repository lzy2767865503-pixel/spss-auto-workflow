import {
  Check,
  ChevronDown,
  FileSpreadsheet,
  FolderOpen,
  Plus,
  Trash2,
  WandSparkles,
} from "lucide-react";
import { useMemo, useState } from "react";

import ItemPicker from "./ItemPicker";

const ANALYSES = [
  { id: "descriptives", label: "描述统计" },
  { id: "reliability", label: "信度分析" },
  { id: "correlations", label: "相关分析" },
  { id: "factor", label: "探索性因子分析" },
  { id: "regression", label: "多元回归" },
];

export default function ConfigureStep({
  job,
  constructs,
  setConstructs,
  models,
  setModels,
  analyses,
  setAnalyses,
  executeSpss,
  setExecuteSpss,
  spss,
  onChangeSheet,
  onRun,
  onReplace,
  error,
}) {
  const [pickerIndex, setPickerIndex] = useState(null);
  const constructOptions = useMemo(
    () => constructs.filter((construct) => construct.items.length > 0),
    [constructs],
  );

  function resetDetected() {
    setConstructs(job.detectedConstructs.map((construct) => ({ ...construct, items: [...construct.items] })));
    setModels(job.suggestedModels.map((model) => ({ ...model, predictors: [...model.predictors] })));
  }

  function addConstruct() {
    setConstructs((current) => [
      ...current,
      {
        id: crypto.randomUUID(),
        name: `Scale_${current.length + 1}`,
        label: "新研究指标",
        items: [],
        detected: false,
      },
    ]);
  }

  function updateConstruct(index, patch) {
    setConstructs((current) =>
      current.map((construct, row) => (row === index ? { ...construct, ...patch } : construct)),
    );
  }

  function addModel() {
    const first = constructOptions[0]?.id || "";
    const second = constructOptions[1]?.id || "";
    setModels((current) => [
      ...current,
      {
        name: `模型 ${current.length + 1}`,
        dependent: second || first,
        predictors: first ? [first] : [],
      },
    ]);
  }

  function updateModel(index, patch) {
    setModels((current) => current.map((model, row) => (row === index ? { ...model, ...patch } : model)));
  }

  function togglePredictor(modelIndex, constructId) {
    const current = models[modelIndex];
    const next = current.predictors.includes(constructId)
      ? current.predictors.filter((id) => id !== constructId)
      : [...current.predictors, constructId];
    updateModel(modelIndex, { predictors: next.filter((id) => id !== current.dependent) });
  }

  return (
    <section className="configure-view">
      <div className="section-block">
        <h2>数据来源</h2>
        <div className="source-row">
          <span className="file-icon"><FileSpreadsheet size={21} /></span>
          <div className="source-name">
            <strong>{job.fileName}</strong>
            <small>{job.rows.toLocaleString()} 行 × {job.columnCount} 列</small>
          </div>
          {job.sheets?.length > 1 ? (
            <label className="sheet-select">
              <span>工作表</span>
              <select value={job.selectedSheet || ""} onChange={(event) => onChangeSheet(event.target.value)}>
                {job.sheets.map((sheet) => <option key={sheet}>{sheet}</option>)}
              </select>
              <ChevronDown size={16} />
            </label>
          ) : null}
          <button className="secondary-button source-action" type="button" onClick={onReplace}>
            <FolderOpen size={18} />更换文件
          </button>
        </div>
        <div className="toolbar-row">
          <button className="accent-button" type="button" onClick={resetDetected}>
            <WandSparkles size={18} />自动识别量表
          </button>
          <button className="secondary-button" type="button" onClick={addConstruct}>
            <Plus size={18} />添加研究指标
          </button>
        </div>
      </div>

      <div className="section-block">
        <div className="section-title-row">
          <div>
            <h2>构念与题项</h2>
            <p>指标名称会成为 SPSS 中的合成变量，得分默认取所选题项平均值。</p>
          </div>
          <span>{constructs.length} 个指标</span>
        </div>
        <div className="construct-table">
          <div className="construct-head">
            <span>构念名称（变量名）</span>
            <span>题项（勾选用于分析的题项）</span>
            <span>操作</span>
          </div>
          {constructs.map((construct, index) => (
            <div className="construct-row" key={construct.id}>
              <div className="construct-name-fields">
                <input
                  value={construct.name}
                  aria-label={`第 ${index + 1} 个构念变量名`}
                  onChange={(event) => updateConstruct(index, { name: event.target.value })}
                />
                <input
                  className="label-input"
                  value={construct.label}
                  aria-label={`第 ${index + 1} 个构念说明`}
                  onChange={(event) => updateConstruct(index, { label: event.target.value })}
                  placeholder="指标中文说明"
                />
              </div>
              <div className="item-chips">
                {construct.items.slice(0, 8).map((item) => (
                  <span className="item-chip" key={item} title={item}>
                    <span className="checked-square"><Check size={12} /></span>
                    {item.length > 18 ? `${item.slice(0, 18)}…` : item}
                  </span>
                ))}
                {construct.items.length > 8 ? <span className="more-count">+{construct.items.length - 8}</span> : null}
                <button className="add-items" type="button" onClick={() => setPickerIndex(index)}>
                  <Plus size={15} />{construct.items.length ? "修改题项" : "添加题项"}
                </button>
              </div>
              <button
                className="icon-button danger"
                type="button"
                title="删除指标"
                onClick={() => setConstructs((current) => current.filter((_, row) => row !== index))}
              >
                <Trash2 size={18} />
              </button>
            </div>
          ))}
          {constructs.length === 0 ? (
            <div className="empty-row">没有识别到量表，请点击“添加研究指标”手动选择题项。</div>
          ) : null}
        </div>
      </div>

      <div className="section-block">
        <h2>选择分析方法（可多选）</h2>
        <div className="analysis-grid">
          {ANALYSES.map((analysis) => {
            const selected = analyses.includes(analysis.id);
            return (
              <button
                type="button"
                aria-label={analysis.label}
                aria-pressed={selected}
                className={selected ? "analysis-option selected" : "analysis-option"}
                key={analysis.id}
                onClick={() =>
                  setAnalyses((current) =>
                    selected ? current.filter((id) => id !== analysis.id) : [...current, analysis.id],
                  )
                }
              >
                <span className="check-box">{selected ? <Check size={14} /> : null}</span>
                {analysis.label}
              </button>
            );
          })}
        </div>
      </div>

      {analyses.includes("regression") ? (
        <div className="section-block">
          <div className="section-title-row">
            <div>
              <h2>多元回归模型设置</h2>
              <p>因变量（DV）只能选一个，自变量（IV）可以选择多个。</p>
            </div>
            <button className="secondary-button small" type="button" onClick={addModel}>
              <Plus size={16} />添加模型
            </button>
          </div>
          <div className="model-list">
            {models.map((model, index) => (
              <div className="model-row" key={`${model.name}-${index}`}>
                <input
                  className="model-name"
                  value={model.name}
                  aria-label={`第 ${index + 1} 个模型名称`}
                  onChange={(event) => updateModel(index, { name: event.target.value })}
                />
                <label>
                  <span>因变量（DV）</span>
                  <select
                    value={model.dependent}
                    onChange={(event) =>
                      updateModel(index, {
                        dependent: event.target.value,
                        predictors: model.predictors.filter((id) => id !== event.target.value),
                      })
                    }
                  >
                    <option value="">请选择</option>
                    {constructOptions.map((construct) => (
                      <option value={construct.id} key={construct.id}>{construct.name}</option>
                    ))}
                  </select>
                </label>
                <fieldset>
                  <legend>自变量（IV，可多选）</legend>
                  <div className="predictor-options">
                    {constructOptions.filter((construct) => construct.id !== model.dependent).map((construct) => {
                      const selected = model.predictors.includes(construct.id);
                      return (
                        <button
                          type="button"
                          aria-pressed={selected}
                          className={selected ? "predictor selected" : "predictor"}
                          key={construct.id}
                          onClick={() => togglePredictor(index, construct.id)}
                        >
                          <span className="check-box">{selected ? <Check size={12} /> : null}</span>
                          {construct.name}
                        </button>
                      );
                    })}
                  </div>
                </fieldset>
                <button
                  className="icon-button danger"
                  type="button"
                  title="删除模型"
                  onClick={() => setModels((current) => current.filter((_, row) => row !== index))}
                >
                  <Trash2 size={18} />
                </button>
              </div>
            ))}
            {models.length === 0 ? <div className="empty-row">点击“添加模型”设置因变量与自变量。</div> : null}
          </div>
        </div>
      ) : null}

      <div className="execution-row">
        <label className="switch-control">
          <input
            type="checkbox"
            checked={executeSpss}
            disabled={!spss?.installed}
            onChange={(event) => setExecuteSpss(event.target.checked)}
          />
          <span className="switch-track"><span /></span>
          <span>
            <strong>使用本机 IBM SPSS Statistics 正式执行</strong>
            <small>
              {spss?.installed
                ? "已检测到安装；许可证与集成只有在真实输出通过验证后才确认"
                : "未检测到用户自行安装的 IBM SPSS；本次仅生成预检与语法"}
            </small>
          </span>
        </label>
        <button className="primary-button run-button" type="button" onClick={onRun}>
          {executeSpss ? "运行预检与 IBM SPSS" : "生成预检与 SPSS 语法"}
        </button>
      </div>
      {error ? <div className="inline-error" role="alert">{error}</div> : null}

      {pickerIndex !== null ? (
        <ItemPicker
          columns={job.numericColumns}
          selected={constructs[pickerIndex]?.items || []}
          onClose={() => setPickerIndex(null)}
          onConfirm={(items) => {
            updateConstruct(pickerIndex, { items });
            setPickerIndex(null);
          }}
        />
      ) : null}
    </section>
  );
}
