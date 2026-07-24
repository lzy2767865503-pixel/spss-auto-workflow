import {
  AlertTriangle,
  CheckCircle2,
  Download,
  FileArchive,
  FileText,
  LoaderCircle,
  RotateCcw,
} from "lucide-react";

import { downloadUrl } from "../api";

function FileIcon({ name }) {
  return name.endsWith(".zip") ? <FileArchive size={19} /> : <FileText size={19} />;
}

function formatBytes(value) {
  if (value >= 1024 * 1024) return `${(value / (1024 * 1024)).toFixed(1)} MB`;
  return `${(value / 1024).toFixed(1)} KB`;
}

export default function RunStep({ job, onReset }) {
  const running = job.status === "running";
  const failed = job.status === "failed";
  const result = job.result;
  const files = [...(result?.files || job.files || [])].sort((left, right) => {
    if (left.name.endsWith(".zip")) return -1;
    if (right.name.endsWith(".zip")) return 1;
    return left.name.localeCompare(right.name);
  });
  const spss = result?.spss;

  return (
    <section className="run-view">
      <div className={`run-state ${failed ? "failed" : running ? "running" : "complete"}`}>
        <span className="run-state-icon">
          {failed ? <AlertTriangle size={27} /> : running ? <LoaderCircle className="spin" size={27} /> : <CheckCircle2 size={27} />}
        </span>
        <div>
          <h2>{failed ? "流程未能完成" : running ? "正在自动分析" : "分析文件已准备好"}</h2>
          <p>{job.message}</p>
        </div>
      </div>

      {running ? (
        <div className="progress-area">
          <div className="progress-label"><span>{job.message}</span><strong>{job.progress || 0}%</strong></div>
          <div className="progress-track"><span style={{ width: `${job.progress || 0}%` }} /></div>
          <p>SPSS 正在运行时可以切换到其他窗口，本页会自动更新。</p>
        </div>
      ) : null}

      {!running && spss ? (
        <div className={`spss-result ${spss.state === "complete" ? "success" : "warning"}`}>
          {spss.state === "complete" ? <CheckCircle2 size={20} /> : <AlertTriangle size={20} />}
          <div>
            <strong>{spss.state === "complete" ? "SPSS 正式输出已完成" : "SPSS 正式输出未完成"}</strong>
            <p>{spss.message}</p>
          </div>
        </div>
      ) : null}

      {!running && files.length ? (
        <div className="download-section">
          <div className="section-title-row">
            <div>
              <h2>下载产出</h2>
              <p>完整包包含数据、SPSS Python 语法、结果表和执行状态。</p>
            </div>
          </div>
          <div className="file-list">
            {files.map((file) => (
              <div className={file.name.endsWith(".zip") ? "file-row bundle" : "file-row"} key={file.name}>
                <span className="file-type"><FileIcon name={file.name} /></span>
                <div>
                  <strong>{file.name}</strong>
                  <small>{file.kind} · {formatBytes(file.size)}</small>
                </div>
                <a className="icon-button download" href={downloadUrl(job.jobId, file.name)} title={`下载 ${file.name}`}>
                  <Download size={18} />
                </a>
              </div>
            ))}
          </div>
        </div>
      ) : null}

      {!running ? (
        <button className="secondary-button restart-button" type="button" onClick={onReset}>
          <RotateCcw size={17} />分析另一份数据
        </button>
      ) : null}
    </section>
  );
}
