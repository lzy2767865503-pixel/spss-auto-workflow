import { AlertTriangle, CheckCircle2, CircleDashed, FileArchive, FileText, LoaderCircle } from "lucide-react";

const LABELS = {
  descriptives: "描述统计",
  reliability: "信度分析",
  correlations: "相关分析",
  factor: "探索性因子分析",
  regression: "多元回归",
};

export default function SummaryPanel({ health, job, constructs, analyses, models, executeSpss }) {
  const complete = job?.status === "complete";
  const formalFailed = job?.status === "formal_failed";
  const filesReady = complete || formalFailed;
  const running = job?.status === "running";
  const files = job?.result?.files || [];
  const spssComplete = job?.result?.spss?.state === "complete";

  return (
    <aside className="summary-panel" aria-label="分析概要">
      <h2>分析概要</h2>
      <section>
        <h3>样本与变量</h3>
        <dl>
          <div><dt>有效导入行数</dt><dd>{job ? job.rows.toLocaleString() : "—"}</dd></div>
          <div><dt>变量总数</dt><dd>{job?.columnCount ?? "—"}</dd></div>
          <div><dt>研究指标</dt><dd>{constructs.length}</dd></div>
        </dl>
      </section>
      <section>
        <h3>已选择的分析</h3>
        {analyses.length ? (
          <ul className="selected-list">
            {analyses.map((id) => <li key={id}>{LABELS[id]}</li>)}
            {analyses.includes("regression") ? <li>{models.length} 个回归模型</li> : null}
          </ul>
        ) : <p className="muted-copy">尚未选择分析方法</p>}
      </section>
      <section>
        <h3>执行状态</h3>
        <ul className="status-list">
          <li className={spssComplete ? "good" : "muted"}>
            {spssComplete ? <CheckCircle2 size={17} /> : <CircleDashed size={17} />}
            {spssComplete ? "IBM SPSS 文件格式完整性已通过" : health?.spss?.installed ? "检测到 IBM SPSS（未验证）" : "未检测到 IBM SPSS"}
          </li>
          <li className="amber"><FileArchive size={17} />{filesReady ? `实际生成 ${files.length} 个文件` : "将生成 Python 预检、语法与下载包"}</li>
          <li className={formalFailed ? "amber" : running ? "running" : "good"}>
            {formalFailed ? <AlertTriangle size={17} /> : running ? <LoaderCircle className="spin" size={17} /> : <CheckCircle2 size={17} />}
            {formalFailed ? "IBM SPSS 正式输出未验证；仅保留预检" : executeSpss ? "请求本机 IBM SPSS 正式执行" : "Python 预检模式（非正式 SPSS 输出）"}
          </li>
        </ul>
      </section>
      <section className="output-preview">
        <h3>输出文件</h3>
        {filesReady ? (
          files.slice(0, 7).map((file) => (
            <div className="output-line" key={file.name}>
              <FileText size={15} />
              <span>{file.name}</span>
            </div>
          ))
        ) : (
          <>
            <div className="output-caption">预检模式会生成</div>
            <div className="output-line"><FileText size={15} /><span>analysis_summary.json</span></div>
            <div className="output-line"><FileText size={15} /><span>analysis_summary_cn.md</span></div>
            <div className="output-line"><FileText size={15} /><span>run_with_spss_python_portable.sps.in</span></div>
            <div className="output-line"><FileArchive size={15} /><span>Survey_Data_Workbench_完整产出.zip</span></div>
            {executeSpss ? <p className="formal-output-note">SAV、SPV、PDF 仅在 IBM SPSS 真实运行且三个文件通过完整解析后出现；发布前语义结果还须在两套获授权 IBM SPSS 环境复核。</p> : null}
          </>
        )}
      </section>
    </aside>
  );
}
