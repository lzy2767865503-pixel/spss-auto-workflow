import { Check } from "lucide-react";

const STEPS = [
  { number: 1, title: "上传数据", pending: "等待上传" },
  { number: 2, title: "选择指标", pending: "等待配置" },
  { number: 3, title: "运行与下载", pending: "待开始" },
];

export default function StepRail({ activeStep, jobStatus }) {
  return (
    <aside className="step-rail" aria-label="分析流程">
      <h1>配置你的研究分析</h1>
      <ol>
        {STEPS.map((step) => {
          const complete = step.number < activeStep || (step.number === 3 && jobStatus === "complete");
          const active = step.number === activeStep;
          return (
            <li key={step.number} className={active ? "active" : complete ? "complete" : ""}>
              <span className="step-number">{complete ? <Check size={18} /> : step.number}</span>
              <span className="step-copy">
                <strong>{step.title}</strong>
                <small>
                  {complete ? "已完成" : active ? (step.number === 3 ? "进行中" : "进行中") : step.pending}
                </small>
              </span>
            </li>
          );
        })}
      </ol>
    </aside>
  );
}
