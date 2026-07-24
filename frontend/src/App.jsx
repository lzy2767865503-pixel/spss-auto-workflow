import { ChartNoAxesCombined, CheckCircle2, HelpCircle, Settings } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";

import { changeSheet, getHealth, getJob, runAnalysis, uploadDataset } from "./api";
import ConfigureStep from "./components/ConfigureStep";
import RunStep from "./components/RunStep";
import StepRail from "./components/StepRail";
import SummaryPanel from "./components/SummaryPanel";
import UploadStep from "./components/UploadStep";

const DEFAULT_ANALYSES = ["descriptives", "reliability", "correlations", "factor", "regression"];

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
  const [executeSpss, setExecuteSpss] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const pollRef = useRef(null);

  useEffect(() => {
    getHealth().then(setHealth).catch((requestError) => setError(requestError.message));
    return () => window.clearTimeout(pollRef.current);
  }, []);

  const activeStep = useMemo(() => {
    if (!job) return 1;
    if (job.status === "running" || job.status === "complete" || job.status === "failed") return 3;
    return 2;
  }, [job]);

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
    setExecuteSpss(true);
    setError("");
  }

  return (
    <div className="app-shell">
      <header className="top-bar">
        <div className="brand">
          <span className="brand-mark"><ChartNoAxesCombined size={23} /></span>
          <strong>SPSS 自动分析台</strong>
        </div>
        <nav aria-label="应用状态与帮助">
          <span className={health?.spss?.installed ? "connection good" : "connection muted"}>
            <CheckCircle2 size={17} />
            {job?.result?.spss?.state === "complete"
              ? "SPSS 已连接"
              : health?.spss?.installed
                ? "SPSS 已安装"
                : "SPSS 未安装"}
          </span>
          <button className="top-icon" type="button" title="设置"><Settings size={19} /></button>
          <button className="top-icon" type="button" title="帮助"><HelpCircle size={19} /></button>
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
    </div>
  );
}
