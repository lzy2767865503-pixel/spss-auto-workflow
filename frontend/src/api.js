async function request(url, options = {}) {
  const response = await fetch(url, options);
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(payload.error || `请求失败（${response.status}）`);
  }
  return payload;
}

export function getHealth() {
  return request("/api/health");
}

export function uploadDataset(file) {
  const body = new FormData();
  body.append("file", file);
  return request("/api/upload", { method: "POST", body });
}

export function changeSheet(jobId, sheet) {
  return request(`/api/jobs/${jobId}/sheet`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ sheet }),
  });
}

export function runAnalysis(jobId, config) {
  return request(`/api/jobs/${jobId}/run`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(config),
  });
}

export function getJob(jobId) {
  return request(`/api/jobs/${jobId}`);
}

export function downloadUrl(jobId, filename) {
  return `/api/jobs/${jobId}/download/${encodeURIComponent(filename)}`;
}
