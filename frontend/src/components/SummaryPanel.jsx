import { CheckCircle2, CircleDashed, FileArchive, FileText, LoaderCircle } from "lucide-react";

const LABELS = {
  descriptives: "描述统计",
  reliability: "信度分析",
  correlations: "相关分析",
  factor: "探索性因子分析",
  regression: "多元回归",
};

export default function SummaryPanel({ health, job, constructs, analyses, models, executeSpss }) {
  const complete = job?.status === "complete";
  const running = job?.status === "running";
  const files = job?.result?.files || [];
  const predicted = 8 + Math.max(0, analyses.length - 3);
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
          <li className={health?.spss?.installed ? "good" : "muted"}>
            {health?.spss?.installed ? <CheckCircle2 size={17} /> : <CircleDashed size={17} />}
            {spssComplete ? "SPSS 已连接" : health?.spss?.installed ? "SPSS 已安装" : "未检测到 SPSS"}
          </li>
          <li className="amber"><FileArchive size={17} />{complete ? `已生成 ${files.length} 个文件` : `将生成约 ${predicted} 个文件`}</li>
          <li className={running ? "running" : "good"}>
            {running ? <LoaderCircle className="spin" size={17} /> : <CheckCircle2 size={17} />}
            {executeSpss ? "Python 自动执行" : "仅生成语法"}
          </li>
        </ul>
      </section>
      <section className="output-preview">
        <h3>输出文件</h3>
        {complete ? (
          files.slice(0, 7).map((file) => (
            <div className="output-line" key={file.name}>
              <FileText size={15} />
              <span>{file.name}</span>
            </div>
          ))
        ) : (
          <>
            <div className="output-line"><FileText size={15} /><span>analysis_output.spv</span></div>
            <div className="output-line"><FileText size={15} /><span>analysis_output.pdf</span></div>
            <div className="output-line"><FileText size={15} /><span>analysis_data.sav</span></div>
            <div className="output-line"><FileText size={15} /><span>analysis_summary_cn.md</span></div>
            <div className="output-line"><FileText size={15} /><span>完整产出.zip</span></div>
          </>
        )}
      </section>
    </aside>
  );
}
