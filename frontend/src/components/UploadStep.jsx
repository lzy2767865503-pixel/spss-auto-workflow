import { FileSpreadsheet, UploadCloud } from "lucide-react";
import { useRef, useState } from "react";

const ACCEPTED = ".xlsx,.xls,.xlsm,.csv,.tsv,.txt,.sav,.zsav,.por";

export default function UploadStep({ onUpload, busy, error }) {
  const inputRef = useRef(null);
  const [dragging, setDragging] = useState(false);

  function submit(file) {
    if (file) onUpload(file);
  }

  return (
    <section className="upload-view" aria-labelledby="upload-title">
      <div>
        <h2 id="upload-title">上传研究数据</h2>
        <p>系统会读取变量、识别量表题项，并为 SPSS 生成安全的变量名。</p>
      </div>

      <button
        className={`drop-zone ${dragging ? "dragging" : ""}`}
        type="button"
        disabled={busy}
        onClick={() => inputRef.current?.click()}
        onDragOver={(event) => {
          event.preventDefault();
          setDragging(true);
        }}
        onDragLeave={() => setDragging(false)}
        onDrop={(event) => {
          event.preventDefault();
          setDragging(false);
          submit(event.dataTransfer.files?.[0]);
        }}
      >
        <UploadCloud size={34} strokeWidth={1.7} />
        <strong>{busy ? "正在读取数据..." : "拖入文件，或点击选择"}</strong>
        <span>支持 Excel、CSV、TXT、SAV、ZSAV 和 POR，最大 200MB</span>
      </button>
      <input
        ref={inputRef}
        className="sr-only"
        type="file"
        accept={ACCEPTED}
        onChange={(event) => submit(event.target.files?.[0])}
      />

      {error ? <div className="inline-error" role="alert">{error}</div> : null}

      <div className="format-strip" aria-label="支持格式">
        <FileSpreadsheet size={20} />
        <span>Excel / CSV</span>
        <span>SAV / ZSAV</span>
        <span>POR / TXT</span>
      </div>
    </section>
  );
}
