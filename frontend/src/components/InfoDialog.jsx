import { Database, HelpCircle, Info, LockKeyhole, Settings, Trash2, X } from "lucide-react";
import { useEffect, useRef, useState } from "react";

import { deleteAllData, getSettings, updateSettings } from "../api";

const SECTIONS = [
  { id: "settings", label: "设置", icon: Settings },
  { id: "help", label: "帮助", icon: HelpCircle },
  { id: "privacy", label: "隐私", icon: LockKeyhole },
  { id: "about", label: "关于", icon: Info },
];

export default function InfoDialog({ initialSection, spss, onClose, onDataDeleted }) {
  const [section, setSection] = useState(initialSection || "settings");
  const [retentionDays, setRetentionDays] = useState(30);
  const [jobCount, setJobCount] = useState(0);
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const dialogRef = useRef(null);

  useEffect(() => {
    getSettings()
      .then((settings) => {
        setRetentionDays(settings.retentionDays);
        setJobCount(settings.jobCount);
      })
      .catch((error) => setNotice(error.message));
  }, []);

  useEffect(() => {
    function handleDialogKeys(event) {
      if (event.key === "Escape") {
        onClose();
        return;
      }
      if (event.key !== "Tab" || !dialogRef.current) return;
      const focusable = [...dialogRef.current.querySelectorAll(
        'button:not([disabled]), input:not([disabled]), select:not([disabled]), a[href], [tabindex]:not([tabindex="-1"])',
      )];
      if (!focusable.length) return;
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    }
    window.addEventListener("keydown", handleDialogKeys);
    return () => window.removeEventListener("keydown", handleDialogKeys);
  }, [onClose]);

  async function saveRetention() {
    setBusy(true);
    setNotice("");
    try {
      const updated = await updateSettings(Number(retentionDays));
      setRetentionDays(updated.retentionDays);
      setNotice(`已保存；同时清理了 ${updated.removedExpiredJobs} 个过期任务。`);
    } catch (error) {
      setNotice(error.message);
    } finally {
      setBusy(false);
    }
  }

  async function clearData() {
    if (!window.confirm("确定删除本应用保存的全部上传数据、任务配置、预检和分析产出吗？保留期设置、技术日志和 WebView2 支持数据不会由此按钮删除。此操作无法撤销。")) return;
    setBusy(true);
    setNotice("");
    try {
      await deleteAllData();
      setJobCount(0);
      setNotice("全部上传数据、任务配置、预检和分析产出已删除；应用设置与支持数据仍保留。");
      onDataDeleted();
    } catch (error) {
      setNotice(error.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="modal-backdrop" role="presentation" onMouseDown={onClose}>
      <section
        className="info-dialog"
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="info-dialog-title"
        onMouseDown={(event) => event.stopPropagation()}
      >
        <header>
          <div>
            <h2 id="info-dialog-title">Survey Data Workbench by LAI ZEYU</h2>
            <p>独立开发的本地问卷数据分析工作台</p>
          </div>
          <button className="icon-button" type="button" onClick={onClose} title="关闭" autoFocus>
            <X size={19} />
          </button>
        </header>
        <div className="info-layout">
          <nav aria-label="应用信息">
            {SECTIONS.map(({ id, label, icon: Icon }) => (
              <button
                className={section === id ? "selected" : ""}
                type="button"
                key={id}
                aria-pressed={section === id}
                onClick={() => setSection(id)}
              >
                <Icon size={17} />{label}
              </button>
            ))}
          </nav>
          <div className="info-content">
            {section === "settings" ? (
              <>
                <h3>本地数据设置</h3>
                <p>上传文件、任务配置、预检和分析产出只保存在此应用的本地数据目录。</p>
                <label className="retention-setting">
                  <span>自动删除超过此天数的任务</span>
                  <input
                    type="number"
                    min="1"
                    max="3650"
                    value={retentionDays}
                    onChange={(event) => setRetentionDays(event.target.value)}
                  />
                </label>
                <button className="secondary-button" type="button" disabled={busy} onClick={saveRetention}>保存保留期</button>
                <div className="data-delete-card">
                  <Database size={20} />
                  <div><strong>{jobCount} 个本地任务</strong><small>包括上传数据、预检结果和下载包</small></div>
                  <button className="danger-button" type="button" disabled={busy} onClick={clearData}><Trash2 size={16} />删除全部任务数据</button>
                </div>
              </>
            ) : null}
            {section === "help" ? (
              <>
                <h3>两种执行模式</h3>
                <ol>
                  <li><strong>Python 预检：</strong>读取数据并生成统计预检、CSV、JSON、中文摘要与 SPSS 语法，不需要 IBM SPSS。</li>
                  <li><strong>IBM SPSS 正式执行：</strong>仅在检测到用户自行安装的 IBM SPSS Statistics 时可选；完成标记、SAV 的 pyreadstat 解析、SPV 的完整 ZIP 读取和 PDF 结构解析全部通过，才显示文件格式完整。</li>
                </ol>
                <p className="notice-box">文件格式完整性不等于统计语义已获发布认证；语义结果仍须在两套独立、获授权的 IBM SPSS Windows 环境与人工基准交叉复核。</p>
                <p className="notice-box">当前状态：{spss?.installed ? "已检测到安装，但许可证和集成尚未验证。" : "未检测到 IBM SPSS；正式执行已关闭。"}</p>
              </>
            ) : null}
            {section === "privacy" ? (
              <>
                <h3>隐私说明</h3>
                <p>Survey Data Workbench by LAI ZEYU 在本机处理上传数据。本应用不内置账号、广告、遥测或云端上传功能，也不出售个人数据。</p>
                <p>上传数据、任务配置和分析产出保存在 Windows 应用的私有本地数据目录，并按设置的保留期清理。你也可以随时用“删除全部任务数据”清除这些内容。</p>
                <p>该按钮不重置保留期设置，也不删除轮转技术日志或 WebView2 支持数据；这些支持数据可通过 Windows 的应用重置或卸载清除。</p>
                <p>如果数据含有敏感个人信息，请确保你有合法处理权限，并在分享下载包前自行检查内容。</p>
              </>
            ) : null}
            {section === "about" ? (
              <>
                <h3>关于 Survey Data Workbench by LAI ZEYU</h3>
                <p>版本 1.1.0 · 由 <strong>LAI ZEYU（来泽宇）</strong> 独立开发的问卷分析桌面工具。</p>
                <p><strong>Requires a separately installed and licensed IBM SPSS Statistics</strong> for optional formal SPSS execution. 本产品不会捆绑 IBM 软件或许可证。</p>
                <div className="trademark-note">
                  本应用并非 IBM 官方产品，与 IBM 无隶属、认可或赞助关系。IBM 和 SPSS 是 International Business Machines Corporation 在多个司法管辖区的商标。
                </div>
              </>
            ) : null}
            {notice ? <p className="dialog-notice" role="status">{notice}</p> : null}
          </div>
        </div>
      </section>
    </div>
  );
}
