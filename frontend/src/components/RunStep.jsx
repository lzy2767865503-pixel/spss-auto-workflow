import {
  AlertTriangle,
  CheckCircle2,
  CircleDashed,
  Download,
  FileArchive,
  FileText,
  LoaderCircle,
  RotateCcw,
} from "lucide-react";
import { useState } from "react";

import { downloadFile } from "../api";

function FileIcon({ name }) {
  return name.endsWith(".zip") ? <FileArchive size={19} /> : <FileText size={19} />;
}

function formatBytes(value) {
  if (value >= 1024 * 1024) return `${(value / (1024 * 1024)).toFixed(1)} MB`;
  return `${(value / 1024).toFixed(1)} KB`;
}

export default function RunStep({ job, onReset }) {
  const [downloadError, setDownloadError] = useState("");
  const running = job.status === "running";
  const failed = job.status === "failed";
  const formalFailed = job.status === "formal_failed";
  const result = job.result;
  const files = [...(result?.files || job.files || [])].sort((left, right) => {
    if (left.name.endsWith(".zip")) return -1;
    if (right.name.endsWith(".zip")) return 1;
    return left.name.localeCompare(right.name);
  });
  const spss = result?.spss;
  const spssComplete = spss?.state === "complete";
  const spssSkipped = spss?.state === "skipped";

  async function handleDownload(filename) {
    setDownloadError("");
    try {
      await downloadFile(job.jobId, filename);
    } catch (error) {
      setDownloadError(error.message);
    }
  }

  return (
    <section className="run-view">
      <div className={`run-state ${failed ? "failed" : formalFailed ? "warning" : running ? "running" : "complete"}`}>
        <span className="run-state-icon">
          {failed || formalFailed ? <AlertTriangle size={27} /> : running ? <LoaderCircle className="spin" size={27} /> : <CheckCircle2 size={27} />}
        </span>
        <div>
          <h2>{failed ? "流程未能完成" : formalFailed ? "预检已完成，正式输出未验证" : running ? "正在自动分析" : "分析文件已准备好"}</h2>
          <p>{job.message}</p>
        </div>
      </div>

      {running ? (
        <div className="progress-area">
          <div className="progress-label"><span>{job.message}</span><strong>{job.progress || 0}%</strong></div>
          <div className="progress-track"><span style={{ width: `${job.progress || 0}%` }} /></div>
          <p>分析在本机运行；本页会自动更新实际进度。</p>
        </div>
      ) : null}

      {!running && spss ? (
        <div className={`spss-result ${spssComplete ? "success" : spssSkipped ? "neutral" : "warning"}`}>
          {spssComplete ? <CheckCircle2 size={20} /> : spssSkipped ? <CircleDashed size={20} /> : <AlertTriangle size={20} />}
          <div>
            <strong>{spssComplete ? "IBM SPSS 文件格式完整性已通过" : spssSkipped ? "本次未运行 IBM SPSS" : "IBM SPSS 正式输出未验证"}</strong>
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
                  <small>
                    {file.kind} · {file.provenance === "ibm_spss_format_validated" ? "IBM SPSS 生成且格式完整" : "预检或支持文件"} · {formatBytes(file.size)}
                  </small>
                </div>
                <button className="icon-button download" type="button" onClick={() => handleDownload(file.name)} title={`下载 ${file.name}`}>
                  <Download size={18} />
                </button>
              </div>
            ))}
          </div>
          {downloadError ? <div className="inline-error" role="alert">{downloadError}</div> : null}
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
