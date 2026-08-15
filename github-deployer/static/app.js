const STORAGE_KEY = "pgenGithubDeployerHost";

const state = {
  files: [],
  selected: new Set(),
  filter: "changes",
  hideExpected: false,
  scanning: false,
  busy: null,
  snapshot: null,
};

const $ = (selector) => document.querySelector(selector);
const els = {
  form: $("#connectionForm"),
  repository: $("#repository"),
  ref: $("#ref"),
  githubToken: $("#githubToken"),
  host: $("#host"),
  user: $("#user"),
  password: $("#password"),
  scan: $("#scanButton"),
  upload: $("#uploadButton"),
  restart: $("#restartButton"),
  restartDaemon: $("#restartDaemonButton"),
  rows: $("#fileRows"),
  selectAll: $("#selectAll"),
  search: $("#searchInput"),
  hideExpected: $("#hideExpected"),
  selectedCount: $("#selectedCount"),
  selectionSize: $("#selectionSize"),
  connection: $("#connectionState"),
  serviceStatus: $("#serviceStatus"),
  snapshotBar: $("#snapshotBar"),
  snapshotTitle: $("#snapshotTitle"),
  snapshotMessage: $("#snapshotMessage"),
  snapshotCommit: $("#snapshotCommit"),
  dialog: $("#confirmDialog"),
  dialogTitle: $("#dialogTitle"),
  dialogText: $("#dialogText"),
  dialogWarning: $("#dialogWarning"),
  dialogConfirm: $("#dialogConfirm"),
};

els.host.value = localStorage.getItem(STORAGE_KEY) || "";

function credentials() {
  return {
    host: els.host.value.trim(),
    user: els.user.value.trim(),
    password: els.password.value,
  };
}

function source() {
  return {
    repository: els.repository.value.trim(),
    ref: els.ref.value.trim(),
    githubToken: els.githubToken.value,
  };
}

async function api(path, body = {}) {
  const response = await fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ...credentials(), ...body }),
  });
  let data;
  try {
    data = await response.json();
  } catch {
    throw new Error(`The local server returned HTTP ${response.status}.`);
  }
  if (!response.ok || !data.ok) {
    throw new Error(data.error || `Request failed (${response.status}).`);
  }
  return data;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function formatBytes(value) {
  if (value == null) return "-";
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(value < 10240 ? 1 : 0)} KB`;
  return `${(value / 1024 / 1024).toFixed(1)} MB`;
}

function formatDate(timestamp) {
  if (!timestamp) return "-";
  return new Intl.DateTimeFormat(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  }).format(new Date(timestamp * 1000));
}

function formatIsoDate(value) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  return new Intl.DateTimeFormat(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  }).format(date);
}

function selectable(file) {
  return file.status !== "same" && !file.expected && !file.protected;
}

function visibleFiles() {
  const query = els.search.value.trim().toLowerCase();
  return state.files.filter((file) => {
    const filterMatches =
      state.filter === "all" ||
      (state.filter === "changes" && file.status !== "same") ||
      (state.filter === "expected" && file.expected) ||
      file.status === state.filter;
    return filterMatches &&
      (!state.hideExpected || !file.expected) &&
      (!query || file.path.toLowerCase().includes(query));
  });
}

function renderRows() {
  const files = visibleFiles();
  if (!files.length) {
    els.rows.innerHTML = `
      <tr class="empty-row"><td colspan="5"><div class="empty-state">
        <span>⌕</span><strong>No files in this view</strong>
        <p>Try another status filter or search.</p>
      </div></td></tr>`;
  } else {
    els.rows.innerHTML = files.map((file) => {
      const checked = state.selected.has(file.path);
      const canSelect = selectable(file);
      const expected = file.expected
        ? `<span class="expected-label">Expected</span><span class="expected-note">${escapeHtml(file.expectedReason)}</span>`
        : "";
      const protectedLabel = file.protected
        ? '<span class="protected-label">Protected</span>'
        : "";
      const warning = file.sensitive
        ? '<span class="warning-mark" title="Device configuration or state file">◆</span>'
        : "";
      const remoteMeta = file.status === "missing"
        ? "not found"
        : `${formatBytes(file.remoteSize)}<br>${formatDate(file.remoteModified)}<br>mode ${escapeHtml(file.remoteMode)}${file.remoteType === "symlink" ? " · link" : ""}`;
      return `
        <tr class="${checked ? "selected" : ""}">
          <td class="check-cell">
            <input class="file-check" type="checkbox" data-path="${escapeHtml(file.path)}"
              ${checked ? "checked" : ""} ${canSelect ? "" : "disabled"}
              aria-label="Select ${escapeHtml(file.path)}">
          </td>
          <td><div class="file-path" title="${escapeHtml(file.path)}">${escapeHtml(file.path)}${warning}</div></td>
          <td><div class="status-stack"><span class="badge ${file.status}">${file.status}</span>${expected}${protectedLabel}</div></td>
          <td><div class="meta">${formatBytes(file.sourceSize)}<br>${formatDate(file.sourceModified)}<br>mode ${escapeHtml(file.sourceMode)}</div></td>
          <td><div class="meta">${remoteMeta}</div></td>
        </tr>`;
    }).join("");
  }
  syncSelectionUi();
}

function syncSelectionUi() {
  const selectedFiles = state.files.filter((file) => state.selected.has(file.path));
  const totalSize = selectedFiles.reduce((total, file) => total + file.sourceSize, 0);
  els.selectedCount.textContent = `${selectedFiles.length} file${selectedFiles.length === 1 ? "" : "s"} selected`;
  els.selectionSize.textContent = selectedFiles.length
    ? `${formatBytes(totalSize)} from pinned commit ${state.snapshot?.commit.slice(0, 8) || ""}`
    : "Choose unexpected changes to deploy";
  els.upload.disabled = !selectedFiles.length || state.scanning || !state.snapshot;

  const choices = visibleFiles().filter(selectable);
  const selectedVisible = choices.filter((file) => state.selected.has(file.path));
  els.selectAll.checked = choices.length > 0 && selectedVisible.length === choices.length;
  els.selectAll.indeterminate = selectedVisible.length > 0 && selectedVisible.length < choices.length;
  els.selectAll.disabled = !choices.length || state.scanning;
  const servicesDisabled = state.scanning;
  els.restart.disabled = servicesDisabled;
  els.restartDaemon.disabled = servicesDisabled;
}

function setCounts(counts = {}) {
  $("#differentCount").textContent = counts.different ?? "-";
  $("#missingCount").textContent = counts.missing ?? "-";
  $("#expectedCount").textContent = counts.expected ?? "-";
  $("#sameCount").textContent = counts.same ?? "-";
}

function showSnapshot(snapshot) {
  state.snapshot = snapshot;
  els.snapshotBar.hidden = false;
  els.snapshotTitle.textContent = `${snapshot.repository} · ${snapshot.ref} · ${formatIsoDate(snapshot.commitDate)}`;
  els.snapshotMessage.textContent = snapshot.commitMessage || "Pinned commit";
  els.snapshotCommit.textContent = snapshot.commit.slice(0, 12);
  els.snapshotCommit.title = snapshot.commit;
}

function updateConnection(busy) {
  state.busy = busy;
  els.connection.className = "connection-state online";
  els.connection.innerHTML = `<span></span><strong>Connected · ${escapeHtml(els.host.value.trim())}</strong>`;
  const daemon = busy?.daemonRunning ? "Daemon running" : "Daemon not detected";
  const renderer = busy?.rendererRunning ? "renderer running" : "renderer not detected";
  els.serviceStatus.textContent = `${daemon}, ${renderer}.`;
  syncSelectionUi();
}

function toast(message, type = "success", duration = 5600) {
  const item = document.createElement("div");
  item.className = `toast ${type}`;
  item.textContent = message;
  $("#toastRegion").append(item);
  setTimeout(() => item.remove(), duration);
}

function setLoading(button, loading) {
  button.classList.toggle("loading", loading);
  button.disabled = loading;
  if (!button.dataset.label) button.dataset.label = button.innerHTML;
  if (loading) {
    button.setAttribute("aria-busy", "true");
  } else {
    button.removeAttribute("aria-busy");
    button.innerHTML = button.dataset.label;
    button.disabled = false;
  }
}

function confirmAction({ title, text, warning = false, confirmLabel = "Continue", danger = false }) {
  els.dialogTitle.textContent = title;
  els.dialogText.textContent = text;
  els.dialogWarning.hidden = !warning;
  els.dialogConfirm.textContent = confirmLabel;
  els.dialogConfirm.className = `button ${danger ? "danger" : "primary"}`;
  els.dialog.showModal();
  return new Promise((resolve) => {
    els.dialog.addEventListener("close", () => resolve(els.dialog.returnValue === "confirm"), { once: true });
  });
}

els.host.addEventListener("change", () => {
  const host = els.host.value.trim();
  if (host) localStorage.setItem(STORAGE_KEY, host);
  else localStorage.removeItem(STORAGE_KEY);
});

els.form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const host = els.host.value.trim();
  if (host) localStorage.setItem(STORAGE_KEY, host);
  state.scanning = true;
  state.selected.clear();
  setLoading(els.scan, true);
  els.scan.innerHTML = '<span class="button-icon">↻</span>Fetching GitHub...';
  els.upload.disabled = true;
  els.restart.disabled = true;
  els.restartDaemon.disabled = true;
  try {
    const data = await api("/api/scan", source());
    state.files = data.files;
    setCounts(data.counts);
    showSnapshot(data.snapshot);
    els.search.disabled = false;
    els.hideExpected.disabled = false;
    updateConnection(data.busy);
    renderRows();
    const changes = data.counts.different + data.counts.missing;
    toast(`Pinned ${data.snapshot.commit.slice(0, 8)}. Found ${changes} differences, including ${data.counts.expected} expected.`);
  } catch (error) {
    els.connection.className = "connection-state offline";
    els.connection.innerHTML = "<span></span><strong>Scan failed</strong>";
    state.busy = null;
    toast(error.message, "error", 9000);
  } finally {
    state.scanning = false;
    setLoading(els.scan, false);
    syncSelectionUi();
  }
});

document.querySelector(".filters").addEventListener("click", (event) => {
  const button = event.target.closest(".filter");
  if (!button) return;
  state.filter = button.dataset.filter;
  document.querySelectorAll(".filter").forEach((item) => item.classList.toggle("active", item === button));
  renderRows();
});

els.search.addEventListener("input", renderRows);

els.hideExpected.addEventListener("change", () => {
  state.hideExpected = els.hideExpected.checked;
  renderRows();
});

els.rows.addEventListener("change", (event) => {
  const checkbox = event.target.closest(".file-check");
  if (!checkbox) return;
  if (checkbox.checked) state.selected.add(checkbox.dataset.path);
  else state.selected.delete(checkbox.dataset.path);
  renderRows();
});

els.selectAll.addEventListener("change", () => {
  visibleFiles().filter(selectable).forEach((file) => {
    if (els.selectAll.checked) state.selected.add(file.path);
    else state.selected.delete(file.path);
  });
  renderRows();
});

els.upload.addEventListener("click", async () => {
  const selected = state.files.filter((file) => state.selected.has(file.path));
  const confirmed = await confirmAction({
    title: `Deploy ${selected.length} file${selected.length === 1 ? "" : "s"}?`,
    text: `Files will come from pinned commit ${state.snapshot.commit.slice(0, 12)}. Existing Pi files will be backed up first. Services will not restart automatically.`,
    warning: selected.some((file) => file.sensitive),
    confirmLabel: "Upload files",
  });
  if (!confirmed) return;
  setLoading(els.upload, true);
  els.upload.innerHTML = "Uploading...";
  try {
    const data = await api("/api/upload", {
      snapshotId: state.snapshot.id,
      paths: selected.map((file) => file.path),
    });
    toast(`${data.uploaded.length} file${data.uploaded.length === 1 ? "" : "s"} uploaded from ${data.commit.slice(0, 8)}.\nBackup: ${data.backup}`, "success", 9000);
    els.form.requestSubmit();
  } catch (error) {
    toast(error.message, "error", 10000);
  } finally {
    setLoading(els.upload, false);
    syncSelectionUi();
  }
});

els.restart.addEventListener("click", async () => {
  const confirmed = await confirmAction({
    title: "Restart the renderer?",
    text: "Current pattern output will briefly disappear while the renderer stops and starts.",
    confirmLabel: "Restart renderer",
    danger: true,
  });
  if (!confirmed) return;
  setLoading(els.restart, true);
  els.restart.innerHTML = '<span class="restart-icon">↻</span>Restarting...';
  try {
    await api("/api/restart");
    toast("Pattern renderer restarted successfully.");
    updateConnection(await api("/api/status"));
  } catch (error) {
    toast(error.message, "error", 9000);
  } finally {
    setLoading(els.restart, false);
    syncSelectionUi();
  }
});

els.restartDaemon.addEventListener("click", async () => {
  const confirmed = await confirmAction({
    title: "Restart the PGenerator daemon?",
    text: "The whole service and renderer will restart. Use this after uploading Perl modules.",
    confirmLabel: "Restart daemon",
    danger: true,
  });
  if (!confirmed) return;
  setLoading(els.restartDaemon, true);
  els.restartDaemon.innerHTML = '<span class="restart-icon">↻</span>Restarting...';
  try {
    const result = await api("/api/restart-daemon");
    toast(result.message || "PGenerator daemon restarted.");
    updateConnection(result.busy || (await api("/api/status")));
  } catch (error) {
    toast(error.message, "error", 9000);
  } finally {
    setLoading(els.restartDaemon, false);
    syncSelectionUi();
  }
});
