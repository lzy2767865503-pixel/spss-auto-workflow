import {
  ChartNoAxesCombined,
  CheckCircle2,
  CircleDashed,
  HelpCircle,
  Info,
  LockKeyhole,
  Settings,
} from "lucide-react";
import { useEffect, useRef, useState } from "react";

import { changeSheet, getHealth, getJob, runAnalysis, uploadDataset } from "./api";
import ConfigureStep from "./components/ConfigureStep";
import InfoDialog from "./components/InfoDialog";
import RunStep from "./components/RunStep";
import StepRail from "./components/StepRail";
import SummaryPanel from "./components/SummaryPanel";
import UploadStep from "./components/UploadStep";

const DEFAULT_ANALYSES = ["descriptives", "reliability", "correlations"];

function cloneConstructs(constructs = []) {
  return constructs.map((construct) => ({ ...construct, items: [...construct.items] }));
}

function cloneModels(models = []) {
  return models.map((model) => ({ ...model, predictors: [...model.predictors] }));
}

export default function App() {
  const [health, setHealth] = useState(null);
  const [job, setJob] = useState(null);
  const [constructs, setConstructs] = useState([]);
  const [models, setModels] = useState([]);
  const [analyses, setAnalyses] = useState(DEFAULT_ANALYSES);
  const [executeSpss, setExecuteSpss] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [dialogSection, setDialogSection] = useState("");
  const pollRef = useRef(null);

  useEffect(() => {
    getHealth().then(setHealth).catch((requestError) => setError(requestError.message));
    return () => window.clearTimeout(pollRef.current);
  }, []);

  const activeStep = !job
    ? 1
    : ["running", "complete", "formal_failed", "failed"].includes(job.status)
      ? 3
      : 2;

  useEffect(() => {
    if (activeStep === 3) window.scrollTo({ top: 0, behavior: "smooth" });
  }, [activeStep]);

  async function handleUpload(file) {
    setBusy(true);
    setError("");
    try {
      const uploaded = await uploadDataset(file);
      setJob(uploaded);
      setConstructs(cloneConstructs(uploaded.detectedConstructs));
      setModels(cloneModels(uploaded.suggestedModels));
    } catch (uploadError) {
      setError(uploadError.message);
    } finally {
      setBusy(false);
    }
  }

  async function handleSheet(sheet) {
    setBusy(true);
    setError("");
    try {
      const updated = await changeSheet(job.jobId, sheet);
      setJob(updated);
      setConstructs(cloneConstructs(updated.detectedConstructs));
      setModels(cloneModels(updated.suggestedModels));
    } catch (sheetError) {
      setError(sheetError.message);
    } finally {
      setBusy(false);
    }
  }

  function validate() {
    const usable = constructs.filter((construct) => construct.name.trim() && construct.items.length > 0);
    if (!usable.length) return "请至少配置一个研究指标并选择题项。";
    if (!analyses.length) return "请至少选择一种分析方法。";
    if (analyses.includes("reliability") && !usable.some((construct) => construct.items.length >= 2)) {
      return "信度分析至少需要一个包含两个题项的指标。";
    }
    if (analyses.includes("regression")) {
      const invalid = models.some((model) => !model.dependent || model.predictors.length === 0);
      if (!models.length || invalid) return "请为每个回归模型设置因变量和至少一个自变量。";
    }
    return "";
  }

  async function pollJob(jobId) {
    try {
      const updated = await getJob(jobId);
      setJob(updated);
      if (updated.status === "running") {
        pollRef.current = window.setTimeout(() => pollJob(jobId), 1200);
      }
    } catch (pollError) {
      setError(pollError.message);
    }
  }

  async function handleRun() {
    const validationError = validate();
    if (validationError) {
      setError(validationError);
      return;
    }
    setError("");
    try {
      const configuredConstructs = constructs
        .filter((construct) => construct.name.trim() && construct.items.length)
        .map((construct) => ({ ...construct, name: construct.name.trim(), label: construct.label.trim() || construct.name.trim() }));
      const started = await runAnalysis(job.jobId, {
        sheet: job.selectedSheet,
        constructs: configuredConstructs,
        analyses,
        models,
        executeSpss,
      });
      setJob(started);
      pollJob(job.jobId);
    } catch (runError) {
      setError(runError.message);
    }
  }

  function reset() {
    window.clearTimeout(pollRef.current);
    setJob(null);
    setConstructs([]);
    setModels([]);
    setAnalyses(DEFAULT_ANALYSES);
    setExecuteSpss(false);
    setError("");
  }

  return (
    <div className="app-shell">
      <header className="top-bar">
        <div className="brand">
          <span className="brand-mark"><ChartNoAxesCombined size={23} /></span>
          <span className="brand-copy"><strong>Survey Data Workbench by LAI ZEYU</strong><small>本地问卷数据分析工作台</small></span>
        </div>
        <nav aria-label="应用状态与帮助">
          <span className={job?.result?.spss?.state === "complete" ? "connection good" : "connection muted"}>
            {job?.result?.spss?.state === "complete" ? <CheckCircle2 size={17} /> : <CircleDashed size={17} />}
            {job?.result?.spss?.state === "complete"
              ? "IBM SPSS 文件格式完整"
              : health?.spss?.installed
                ? "IBM SPSS 已检测（未验证）"
                : "IBM SPSS 未检测"}
          </span>
          <button className="top-icon" type="button" title="设置" aria-label="设置" onClick={() => setDialogSection("settings")}><Settings size={19} /></button>
          <button className="top-icon" type="button" title="帮助" aria-label="帮助" onClick={() => setDialogSection("help")}><HelpCircle size={19} /></button>
          <button className="top-link" type="button" aria-label="隐私" onClick={() => setDialogSection("privacy")}><LockKeyhole size={16} /><span>隐私</span></button>
          <button className="top-link" type="button" aria-label="关于" onClick={() => setDialogSection("about")}><Info size={16} /><span>关于</span></button>
        </nav>
      </header>

      <div className="workspace">
        <StepRail activeStep={activeStep} jobStatus={job?.status} />
        <main className="main-workspace">
          {!job ? (
            <UploadStep onUpload={handleUpload} busy={busy} error={error} />
          ) : activeStep === 2 ? (
            <ConfigureStep
              job={job}
              constructs={constructs}
              setConstructs={setConstructs}
              models={models}
              setModels={setModels}
              analyses={analyses}
              setAnalyses={setAnalyses}
              executeSpss={executeSpss}
              setExecuteSpss={setExecuteSpss}
              spss={health?.spss}
              onChangeSheet={handleSheet}
              onRun={handleRun}
              onReplace={reset}
              error={error}
            />
          ) : (
            <RunStep job={job} onReset={reset} />
          )}
        </main>
        <SummaryPanel
          health={health}
          job={job}
          constructs={constructs}
          analyses={analyses}
          models={models}
          executeSpss={executeSpss}
        />
      </div>
      {dialogSection ? (
        <InfoDialog
          initialSection={dialogSection}
          spss={health?.spss}
          onClose={() => setDialogSection("")}
          onDataDeleted={reset}
        />
      ) : null}
    </div>
  );
}
