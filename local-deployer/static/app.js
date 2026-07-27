const state = {
  files: [],
  selected: new Set(),
  filter: "changes",
  scanning: false,
  busy: null,
};

const $ = (selector) => document.querySelector(selector);
const els = {
  form: $("#connectionForm"),
  host: $("#host"),
  user: $("#user"),
  password: $("#password"),
  scan: $("#scanButton"),
  upload: $("#uploadButton"),
  restart: $("#restartButton"),
  rows: $("#fileRows"),
  selectAll: $("#selectAll"),
  search: $("#searchInput"),
  selectedCount: $("#selectedCount"),
  selectionSize: $("#selectionSize"),
  connection: $("#connectionState"),
  rendererStatus: $("#rendererStatus"),
  dialog: $("#confirmDialog"),
  dialogTitle: $("#dialogTitle"),
  dialogText: $("#dialogText"),
  dialogWarning: $("#dialogWarning"),
  dialogConfirm: $("#dialogConfirm"),
};

function connection() {
  return {
    host: els.host.value.trim(),
    user: els.user.value.trim(),
    password: els.password.value,
  };
}

async function api(path, body) {
  const response = await fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ...connection(), ...body }),
  });
  let data;
  try {
    data = await response.json();
  } catch {
    throw new Error(`The local server returned HTTP ${response.status}.`);
  }
  if (!response.ok || !data.ok) throw new Error(data.error || `Request failed (${response.status}).`);
  return data;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function formatBytes(value) {
  if (value == null) return "—";
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(value < 10240 ? 1 : 0)} KB`;
  return `${(value / 1024 / 1024).toFixed(1)} MB`;
}

function formatDate(timestamp) {
  if (!timestamp) return "—";
  return new Intl.DateTimeFormat(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  }).format(new Date(timestamp * 1000));
}

function visibleFiles() {
  const query = els.search.value.trim().toLowerCase();
  return state.files.filter((file) => {
    const filterMatches =
      state.filter === "all" ||
      (state.filter === "changes" && file.status !== "same") ||
      file.status === state.filter;
    return filterMatches && (!query || file.path.toLowerCase().includes(query));
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
      const selectable = file.status !== "same";
      const warning = file.sensitive
        ? '<span class="warning-mark" title="Device configuration or state file">◆</span>'
        : "";
      return `
        <tr class="${checked ? "selected" : ""}">
          <td class="check-cell">
            <input class="file-check" type="checkbox" data-path="${escapeHtml(file.path)}"
              ${checked ? "checked" : ""} ${selectable ? "" : "disabled"}
              aria-label="Select ${escapeHtml(file.path)}">
          </td>
          <td><div class="file-path" title="${escapeHtml(file.path)}">${escapeHtml(file.path)}${warning}</div></td>
          <td><span class="badge ${file.status}">${file.status}</span></td>
          <td><div class="meta">${formatBytes(file.localSize)}<br>${formatDate(file.localModified)}<br>mode ${escapeHtml(file.localMode)}</div></td>
          <td><div class="meta">${file.status === "missing" ? "not found" : `${formatBytes(file.remoteSize)}<br>${formatDate(file.remoteModified)}<br>mode ${escapeHtml(file.remoteMode)}`}</div></td>
        </tr>`;
    }).join("");
  }
  syncSelectionUi();
}

function syncSelectionUi() {
  const selectedFiles = state.files.filter((file) => state.selected.has(file.path));
  const totalSize = selectedFiles.reduce((total, file) => total + file.localSize, 0);
  els.selectedCount.textContent = `${selectedFiles.length} file${selectedFiles.length === 1 ? "" : "s"} selected`;
  els.selectionSize.textContent = selectedFiles.length
    ? `${formatBytes(totalSize)} will be uploaded · remote originals will be backed up`
    : "Choose changed files to deploy";
  els.upload.disabled = !selectedFiles.length || state.scanning;

  const selectable = visibleFiles().filter((file) => file.status !== "same");
  const selectedVisible = selectable.filter((file) => state.selected.has(file.path));
  els.selectAll.checked = selectable.length > 0 && selectedVisible.length === selectable.length;
  els.selectAll.indeterminate = selectedVisible.length > 0 && selectedVisible.length < selectable.length;
  els.selectAll.disabled = !selectable.length || state.scanning;
  els.restart.disabled = !state.busy?.idle || state.scanning;
}

function setCounts(counts = {}) {
  $("#differentCount").textContent = counts.different ?? "—";
  $("#missingCount").textContent = counts.missing ?? "—";
  $("#sameCount").textContent = counts.same ?? "—";
}

function updateConnection(busy) {
  state.busy = busy;
  els.connection.className = `connection-state ${busy && !busy.idle ? "busy" : "online"}`;
  els.connection.innerHTML = `<span></span><strong>${busy && !busy.idle ? "Pi busy" : `Connected · ${escapeHtml(els.host.value.trim())}`}</strong>`;
  els.rendererStatus.textContent = busy?.rendererRunning
    ? (busy.idle ? "Renderer is running. The Pi is idle and safe for maintenance." : "Renderer is running, but a meter or calibration process is active.")
    : "Renderer process was not detected.";
  els.restart.disabled = !busy?.idle || state.scanning;
}

function toast(message, type = "success", duration = 5200) {
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
  if (loading) button.setAttribute("aria-busy", "true");
  else {
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

els.form.addEventListener("submit", async (event) => {
  event.preventDefault();
  state.scanning = true;
  setLoading(els.scan, true);
  els.scan.innerHTML = '<span class="button-icon">↻</span>Scanning…';
  els.upload.disabled = true;
  els.restart.disabled = true;
  try {
    const data = await api("/api/scan", {});
    state.files = data.files;
    state.selected.clear();
    setCounts(data.counts);
    els.search.disabled = false;
    updateConnection(data.busy);
    renderRows();
    toast(`Scan complete. ${data.counts.different + data.counts.missing} file differences found.`);
  } catch (error) {
    els.connection.className = "connection-state offline";
    els.connection.innerHTML = "<span></span><strong>Connection failed</strong>";
    state.busy = null;
    toast(error.message, "error", 8000);
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

els.rows.addEventListener("change", (event) => {
  const checkbox = event.target.closest(".file-check");
  if (!checkbox) return;
  if (checkbox.checked) state.selected.add(checkbox.dataset.path);
  else state.selected.delete(checkbox.dataset.path);
  renderRows();
});

els.selectAll.addEventListener("change", () => {
  visibleFiles().filter((file) => file.status !== "same").forEach((file) => {
    if (els.selectAll.checked) state.selected.add(file.path);
    else state.selected.delete(file.path);
  });
  renderRows();
});

els.upload.addEventListener("click", async () => {
  const selected = state.files.filter((file) => state.selected.has(file.path));
  const confirmed = await confirmAction({
    title: `Deploy ${selected.length} file${selected.length === 1 ? "" : "s"}?`,
    text: "Each existing remote file will be backed up before the replacement is installed. The renderer will not restart automatically.",
    warning: selected.some((file) => file.sensitive),
    confirmLabel: "Upload files",
  });
  if (!confirmed) return;
  setLoading(els.upload, true);
  els.upload.innerHTML = "Uploading…";
  try {
    const data = await api("/api/upload", { paths: selected.map((file) => file.path) });
    toast(`${data.uploaded.length} file${data.uploaded.length === 1 ? "" : "s"} uploaded.\nBackup: ${data.backup}`, "success", 9000);
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
    text: "The current pattern output will briefly disappear while PGeneratord stops and starts.",
    confirmLabel: "Restart renderer",
    danger: true,
  });
  if (!confirmed) return;
  setLoading(els.restart, true);
  els.restart.innerHTML = '<span class="restart-icon">↻</span>Restarting…';
  try {
    await api("/api/restart", {});
    toast("Pattern renderer restarted successfully.");
    const busy = await api("/api/status", {});
    updateConnection(busy);
  } catch (error) {
    toast(error.message, "error", 9000);
  } finally {
    setLoading(els.restart, false);
    syncSelectionUi();
  }
});
