const hash = new URLSearchParams(window.location.hash.replace(/^#/, ""));
const apiToken = window.__STATFLOW_RUNTIME__?.apiToken || hash.get("token") || "";

if (hash.has("token")) {
  window.history.replaceState(null, "", `${window.location.pathname}${window.location.search}`);
}

function authenticatedHeaders(input) {
  const headers = new Headers(input || {});
  if (apiToken) headers.set("X-StatFlow-Token", apiToken);
  return headers;
}

async function request(url, options = {}) {
  const response = await fetch(url, { ...options, headers: authenticatedHeaders(options.headers) });
  if (response.status === 204) return null;
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    const message = typeof payload.error === "object" ? payload.error.message : payload.error;
    throw new Error(message || `请求失败（${response.status}）`);
  }
  return payload;
}

export function getHealth() {
  return request("/api/health");
}

export function getSettings() {
  return request("/api/settings");
}

export function updateSettings(retentionDays) {
  return request("/api/settings", {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ retentionDays }),
  });
}

export function deleteAllData() {
  return request("/api/data", { method: "DELETE" });
}

export function deleteJob(jobId) {
  return request(`/api/jobs/${jobId}`, { method: "DELETE" });
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

export async function downloadFile(jobId, filename) {
  const response = await fetch(`/api/jobs/${jobId}/download/${encodeURIComponent(filename)}`, {
    headers: authenticatedHeaders(),
  });
  if (!response.ok) {
    const payload = await response.json().catch(() => ({}));
    const message = typeof payload.error === "object" ? payload.error.message : payload.error;
    throw new Error(message || `下载失败（${response.status}）`);
  }
  const blob = await response.blob();
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = filename;
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 1000);
}
