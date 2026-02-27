#!/usr/bin/env python3
"""
Pgen Companion — Local desktop controller for PGenerator.

A replacement for DeviceControl that works entirely over local TCP
(WiFi, Bluetooth PAN, USB gadget, or Ethernet) without any cloud account.

Requires Python 3.10+ and tkinter (bundled with Python on Windows).
"""

import sys
import os
import threading
import time
import tkinter as tk
from tkinter import ttk, messagebox, scrolledtext

# Local module
from pgen_client import PGenClient

# ---------------------------------------------------------------------------
# Known PGenerator network addresses (from rcPGenerator defaults)
# ---------------------------------------------------------------------------
BT_PAN_IP = "10.10.11.1"     # bnep (Bluetooth PAN, PAND_NET)
WIFI_AP_IP = "10.10.10.1"    # ap0 (WiFi AP, AP_NET)
USB_IP = "10.10.12.1"        # usb0 (USB gadget)
DIRECT_IP = "10.10.13.1"     # DirectLan

KNOWN_IPS = [BT_PAN_IP, WIFI_AP_IP, USB_IP, DIRECT_IP]

VERSION = "1.0.0"


# ===========================================================================
# Main Application
# ===========================================================================
class PgenCompanionApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Pgen Companion")
        self.geometry("920x720")
        self.minsize(800, 600)
        # Set window icon
        try:
            ico_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Pgenerator.ico")
            if os.path.isfile(ico_path):
                self.iconbitmap(ico_path)
        except Exception:
            pass
        self.protocol("WM_DELETE_WINDOW", self._on_close)

        self.client: PGenClient | None = None
        self._poll_id: str | None = None

        self._build_ui()
        # Try auto-connect on startup
        self.after(200, self._auto_connect)

    # ------------------------------------------------------------------
    # UI Construction
    # ------------------------------------------------------------------
    def _build_ui(self):
        # Top connection bar
        conn_frame = ttk.Frame(self, padding=4)
        conn_frame.pack(fill=tk.X)

        ttk.Label(conn_frame, text="IP:").pack(side=tk.LEFT)
        self.ip_var = tk.StringVar(value=BT_PAN_IP)
        self.ip_entry = ttk.Combobox(conn_frame, textvariable=self.ip_var,
                                     values=KNOWN_IPS, width=18)
        self.ip_entry.pack(side=tk.LEFT, padx=4)
        self.connect_btn = ttk.Button(conn_frame, text="Connect",
                                      command=self._connect)
        self.connect_btn.pack(side=tk.LEFT, padx=2)
        self.disconnect_btn = ttk.Button(conn_frame, text="Disconnect",
                                         command=self._disconnect,
                                         state=tk.DISABLED)
        self.disconnect_btn.pack(side=tk.LEFT, padx=2)
        ttk.Button(conn_frame, text="Discover",
                   command=self._discover).pack(side=tk.LEFT, padx=2)

        self.status_var = tk.StringVar(value="Disconnected")
        ttk.Label(conn_frame, textvariable=self.status_var,
                  foreground="gray").pack(side=tk.RIGHT, padx=8)

        # Notebook with tabs
        self.notebook = ttk.Notebook(self, padding=4)
        self.notebook.pack(fill=tk.BOTH, expand=True)

        self._build_system_tab()
        self._build_signal_tab()
        self._build_hdr_tab()
        self._build_pattern_tab()
        self._build_network_tab()
        self._build_edid_tab()

    # ======================================================================
    # TAB 1 — System
    # ======================================================================
    def _build_system_tab(self):
        tab = ttk.Frame(self.notebook, padding=8)
        self.notebook.add(tab, text="System")

        row = 0
        self.sys_fields: dict[str, tk.StringVar] = {}
        labels = [
            ("Version", "version"),
            ("Model", "model"),
            ("Hostname", "hostname"),
            ("Temperature", "temperature"),
            ("Resolution", "resolution"),
            ("HDMI Info", "hdmi_info"),
            ("Uptime", "uptime"),
        ]
        for label, key in labels:
            ttk.Label(tab, text=f"{label}:", anchor=tk.W).grid(
                row=row, column=0, sticky=tk.W, padx=4, pady=2)
            var = tk.StringVar(value="—")
            self.sys_fields[key] = var
            ttk.Label(tab, textvariable=var, anchor=tk.W,
                      wraplength=500).grid(
                row=row, column=1, sticky=tk.W, padx=4, pady=2)
            row += 1

        btn_frame = ttk.Frame(tab)
        btn_frame.grid(row=row, column=0, columnspan=2, pady=12)
        ttk.Button(btn_frame, text="Refresh",
                   command=self._refresh_system).pack(side=tk.LEFT, padx=4)
        ttk.Button(btn_frame, text="Restart PGenerator",
                   command=self._restart_pg).pack(side=tk.LEFT, padx=4)
        ttk.Button(btn_frame, text="Reboot Device",
                   command=self._reboot).pack(side=tk.LEFT, padx=4)

    # ======================================================================
    # TAB 2 — Signal Mode (AVI InfoFrame)
    # ======================================================================
    def _build_signal_tab(self):
        tab = ttk.Frame(self.notebook, padding=8)
        self.notebook.add(tab, text="Signal Mode")

        row = 0

        # Signal Mode
        ttk.Label(tab, text="Output Mode:").grid(row=row, column=0,
                                                  sticky=tk.W, padx=4)
        self.signal_mode_var = tk.StringVar(value="SDR")
        mode_combo = ttk.Combobox(tab, textvariable=self.signal_mode_var,
                                  values=["SDR", "HDR10", "HLG",
                                          "Dolby Vision LL", "Dolby Vision Std"],
                                  state="readonly", width=22)
        mode_combo.grid(row=row, column=1, sticky=tk.W, padx=4, pady=4)
        row += 1

        # Color Format
        ttk.Label(tab, text="Color Format:").grid(row=row, column=0,
                                                   sticky=tk.W, padx=4)
        self.color_format_var = tk.StringVar(value="0")
        cf_combo = ttk.Combobox(tab, textvariable=self.color_format_var,
                                values=["0 — RGB", "1 — YCbCr 444",
                                        "2 — YCbCr 422", "3 — YCbCr 420"],
                                state="readonly", width=22)
        cf_combo.grid(row=row, column=1, sticky=tk.W, padx=4, pady=4)
        row += 1

        # Colorimetry
        ttk.Label(tab, text="Colorimetry:").grid(row=row, column=0,
                                                  sticky=tk.W, padx=4)
        self.colorimetry_var = tk.StringVar(value="0")
        cl_combo = ttk.Combobox(tab, textvariable=self.colorimetry_var,
                                values=["0 — BT.709", "1 — BT.2020"],
                                state="readonly", width=22)
        cl_combo.grid(row=row, column=1, sticky=tk.W, padx=4, pady=4)
        row += 1

        # Quantization Range
        ttk.Label(tab, text="Quantization Range:").grid(row=row, column=0,
                                                         sticky=tk.W, padx=4)
        self.quant_range_var = tk.StringVar(value="2")
        qr_combo = ttk.Combobox(tab, textvariable=self.quant_range_var,
                                values=["0 — Default", "1 — Limited (16-235)",
                                        "2 — Full (0-255)"],
                                state="readonly", width=22)
        qr_combo.grid(row=row, column=1, sticky=tk.W, padx=4, pady=4)
        row += 1

        # Bit Depth
        ttk.Label(tab, text="Bit Depth:").grid(row=row, column=0,
                                                sticky=tk.W, padx=4)
        self.bit_depth_var = tk.StringVar(value="8")
        bd_combo = ttk.Combobox(tab, textvariable=self.bit_depth_var,
                                values=["8", "10", "12"],
                                state="readonly", width=22)
        bd_combo.grid(row=row, column=1, sticky=tk.W, padx=4, pady=4)
        row += 1

        ttk.Separator(tab, orient=tk.HORIZONTAL).grid(
            row=row, column=0, columnspan=2, sticky=tk.EW, pady=8)
        row += 1

        btn_frame = ttk.Frame(tab)
        btn_frame.grid(row=row, column=0, columnspan=2, pady=4)
        ttk.Button(btn_frame, text="Apply Signal Settings",
                   command=self._apply_signal).pack(side=tk.LEFT, padx=4)
        ttk.Button(btn_frame, text="Read Current",
                   command=self._read_signal).pack(side=tk.LEFT, padx=4)

    # ======================================================================
    # TAB 3 — HDR / DRM InfoFrame
    # ======================================================================
    def _build_hdr_tab(self):
        tab = ttk.Frame(self.notebook, padding=8)
        self.notebook.add(tab, text="HDR / DV")

        row = 0
        # EOTF
        ttk.Label(tab, text="EOTF:").grid(row=row, column=0,
                                           sticky=tk.W, padx=4)
        self.eotf_var = tk.StringVar(value="2")
        eotf_combo = ttk.Combobox(
            tab, textvariable=self.eotf_var,
            values=["0 — SDR Gamma", "1 — HDR Gamma",
                    "2 — SMPTE ST.2084 (PQ)", "3 — HLG"],
            state="readonly", width=28)
        eotf_combo.grid(row=row, column=1, sticky=tk.W, padx=4, pady=4)
        row += 1

        # Primaries
        ttk.Label(tab, text="Primaries:").grid(row=row, column=0,
                                                sticky=tk.W, padx=4)
        self.primaries_var = tk.StringVar(value="1")
        prim_combo = ttk.Combobox(
            tab, textvariable=self.primaries_var,
            values=["0 — Custom / BT.709", "1 — BT.2020 / D65",
                    "2 — P3 / D65", "3 — P3 / DCI Theater"],
            state="readonly", width=28)
        prim_combo.grid(row=row, column=1, sticky=tk.W, padx=4, pady=4)
        row += 1

        # Max Luminance
        ttk.Label(tab, text="Max Luminance (nits):").grid(
            row=row, column=0, sticky=tk.W, padx=4)
        self.max_luma_var = tk.StringVar(value="1000")
        ttk.Entry(tab, textvariable=self.max_luma_var,
                  width=10).grid(row=row, column=1, sticky=tk.W, padx=4, pady=4)
        row += 1

        # Min Luminance
        ttk.Label(tab, text="Min Luminance:").grid(
            row=row, column=0, sticky=tk.W, padx=4)
        self.min_luma_var = tk.StringVar(value="5")
        ttk.Entry(tab, textvariable=self.min_luma_var,
                  width=10).grid(row=row, column=1, sticky=tk.W, padx=4, pady=4)
        row += 1

        # MaxCLL
        ttk.Label(tab, text="MaxCLL:").grid(
            row=row, column=0, sticky=tk.W, padx=4)
        self.max_cll_var = tk.StringVar(value="1000")
        ttk.Entry(tab, textvariable=self.max_cll_var,
                  width=10).grid(row=row, column=1, sticky=tk.W, padx=4, pady=4)
        row += 1

        # MaxFALL
        ttk.Label(tab, text="MaxFALL:").grid(
            row=row, column=0, sticky=tk.W, padx=4)
        self.max_fall_var = tk.StringVar(value="250")
        ttk.Entry(tab, textvariable=self.max_fall_var,
                  width=10).grid(row=row, column=1, sticky=tk.W, padx=4, pady=4)
        row += 1

        ttk.Separator(tab, orient=tk.HORIZONTAL).grid(
            row=row, column=0, columnspan=2, sticky=tk.EW, pady=8)
        row += 1

        # DV section header
        ttk.Label(tab, text="Dolby Vision", font=("", 10, "bold")).grid(
            row=row, column=0, columnspan=2, sticky=tk.W, padx=4, pady=4)
        row += 1

        # DV Status
        ttk.Label(tab, text="DV Status:").grid(row=row, column=0,
                                                sticky=tk.W, padx=4)
        self.dv_status_var = tk.StringVar(value="0")
        dv_combo = ttk.Combobox(tab, textvariable=self.dv_status_var,
                                values=["0 — Disabled", "1 — Enabled"],
                                state="readonly", width=22)
        dv_combo.grid(row=row, column=1, sticky=tk.W, padx=4, pady=4)
        row += 1

        # DV Color Space
        ttk.Label(tab, text="DV Color Space:").grid(row=row, column=0,
                                                     sticky=tk.W, padx=4)
        self.dv_cs_var = tk.StringVar(value="0")
        dvcs_combo = ttk.Combobox(
            tab, textvariable=self.dv_cs_var,
            values=["0 — YCbCr 422 (12-bit)", "1 — RGB 444 (8-bit tunnel)",
                    "2 — YCbCr 444 (10-bit)"],
            state="readonly", width=28)
        dvcs_combo.grid(row=row, column=1, sticky=tk.W, padx=4, pady=4)
        row += 1

        # DV Metadata
        ttk.Label(tab, text="DV Metadata:").grid(row=row, column=0,
                                                  sticky=tk.W, padx=4)
        self.dv_meta_var = tk.StringVar(value="0")
        dvm_combo = ttk.Combobox(tab, textvariable=self.dv_meta_var,
                                 values=["0 — Type 1 (static)",
                                         "1 — Type 4 (dynamic)"],
                                 state="readonly", width=22)
        dvm_combo.grid(row=row, column=1, sticky=tk.W, padx=4, pady=4)
        row += 1

        btn_frame = ttk.Frame(tab)
        btn_frame.grid(row=row, column=0, columnspan=2, pady=8)
        ttk.Button(btn_frame, text="Apply HDR/DV Settings",
                   command=self._apply_hdr).pack(side=tk.LEFT, padx=4)
        ttk.Button(btn_frame, text="Read Current",
                   command=self._read_hdr).pack(side=tk.LEFT, padx=4)

    # ======================================================================
    # TAB 4 — Pattern
    # ======================================================================
    def _build_pattern_tab(self):
        tab = ttk.Frame(self.notebook, padding=8)
        self.notebook.add(tab, text="Pattern")

        row = 0
        ttk.Label(tab, text="Draw:").grid(row=row, column=0,
                                           sticky=tk.W, padx=4)
        self.pat_draw_var = tk.StringVar(value="RECTANGLE")
        ttk.Combobox(tab, textvariable=self.pat_draw_var,
                     values=["RECTANGLE", "CIRCLE", "TRIANGLE"],
                     state="readonly", width=16).grid(
            row=row, column=1, sticky=tk.W, padx=4, pady=4)
        row += 1

        ttk.Label(tab, text="Width:").grid(row=row, column=0,
                                            sticky=tk.W, padx=4)
        self.pat_w_var = tk.StringVar(value="1920")
        ttk.Entry(tab, textvariable=self.pat_w_var,
                  width=8).grid(row=row, column=1, sticky=tk.W, padx=4, pady=2)
        row += 1

        ttk.Label(tab, text="Height:").grid(row=row, column=0,
                                             sticky=tk.W, padx=4)
        self.pat_h_var = tk.StringVar(value="1080")
        ttk.Entry(tab, textvariable=self.pat_h_var,
                  width=8).grid(row=row, column=1, sticky=tk.W, padx=4, pady=2)
        row += 1

        ttk.Label(tab, text="Resolution %:").grid(row=row, column=0,
                                                    sticky=tk.W, padx=4)
        self.pat_res_var = tk.StringVar(value="100")
        ttk.Entry(tab, textvariable=self.pat_res_var,
                  width=8).grid(row=row, column=1, sticky=tk.W, padx=4, pady=2)
        row += 1

        # RGB sliders
        for color, default in [("Red", 128), ("Green", 128), ("Blue", 128)]:
            ttk.Label(tab, text=f"{color}:").grid(row=row, column=0,
                                                   sticky=tk.W, padx=4)
            var = tk.IntVar(value=default)
            setattr(self, f"pat_{color.lower()}_var", var)
            scale = ttk.Scale(tab, from_=0, to=255, variable=var,
                              orient=tk.HORIZONTAL, length=200)
            scale.grid(row=row, column=1, sticky=tk.W, padx=4, pady=2)
            lbl_var = tk.StringVar(value=str(default))
            ttk.Label(tab, textvariable=lbl_var, width=4).grid(
                row=row, column=2, padx=2)
            var.trace_add("write", lambda *a, v=var, l=lbl_var: l.set(str(v.get())))
            row += 1

        # Background RGB
        ttk.Label(tab, text="BG (R,G,B):").grid(row=row, column=0,
                                                  sticky=tk.W, padx=4)
        self.pat_bg_var = tk.StringVar(value="0,0,0")
        ttk.Entry(tab, textvariable=self.pat_bg_var,
                  width=12).grid(row=row, column=1, sticky=tk.W, padx=4, pady=2)
        row += 1

        # Color preview
        self.color_preview = tk.Canvas(tab, width=60, height=40,
                                       bg="#808080", relief=tk.SUNKEN, bd=1)
        self.color_preview.grid(row=row, column=1, sticky=tk.W, padx=4, pady=4)
        for color in ("red", "green", "blue"):
            getattr(self, f"pat_{color}_var").trace_add(
                "write", lambda *a: self._update_color_preview())
        row += 1

        btn_frame = ttk.Frame(tab)
        btn_frame.grid(row=row, column=0, columnspan=3, pady=8)
        ttk.Button(btn_frame, text="Send Pattern",
                   command=self._send_pattern).pack(side=tk.LEFT, padx=4)

    # ======================================================================
    # TAB 5 — Network
    # ======================================================================
    def _build_network_tab(self):
        tab = ttk.Frame(self.notebook, padding=8)
        self.notebook.add(tab, text="Network")

        row = 0
        self.net_fields: dict[str, tk.StringVar] = {}
        labels = [
            ("WiFi AP IP", "ip_ap0"),
            ("WiFi AP MAC", "mac_ap0"),
            ("WiFi Client IP", "ip_wlan0"),
            ("WiFi Client MAC", "mac_wlan0"),
            ("Ethernet IP", "ip_eth0"),
            ("Ethernet MAC", "mac_eth0"),
            ("Bluetooth IP", "ip_bnep"),
            ("Bluetooth MAC", "mac_bnep"),
            ("USB IP", "ip_usb0"),
        ]
        for label, key in labels:
            ttk.Label(tab, text=f"{label}:", anchor=tk.W).grid(
                row=row, column=0, sticky=tk.W, padx=4, pady=2)
            var = tk.StringVar(value="—")
            self.net_fields[key] = var
            ttk.Label(tab, textvariable=var).grid(
                row=row, column=1, sticky=tk.W, padx=4, pady=2)
            row += 1

        ttk.Button(tab, text="Refresh Network Info",
                   command=self._refresh_network).grid(
            row=row, column=0, columnspan=2, pady=8)

    # ======================================================================
    # TAB 6 — EDID
    # ======================================================================
    def _build_edid_tab(self):
        tab = ttk.Frame(self.notebook, padding=8)
        self.notebook.add(tab, text="EDID")

        self.edid_text = scrolledtext.ScrolledText(tab, wrap=tk.WORD,
                                                    height=30, width=90,
                                                    font=("Consolas", 9))
        self.edid_text.pack(fill=tk.BOTH, expand=True, padx=4, pady=4)
        ttk.Button(tab, text="Read EDID",
                   command=self._read_edid).pack(pady=4)

    # ------------------------------------------------------------------
    # Connection
    # ------------------------------------------------------------------
    def _auto_connect(self):
        """Try known IPs in order, then fall back to UDP discovery."""
        self.status_var.set("Auto-connecting...")
        self.update_idletasks()

        def _try_connect():
            # First try known IPs with a short timeout
            for ip in KNOWN_IPS:
                try:
                    c = PGenClient(ip, timeout=1.5)
                    c.connect()
                    if c.is_alive():
                        return c
                    c.close()
                except Exception:
                    pass
            # Fall back to broadcast discovery
            found = PGenClient.discover(timeout=2.0)
            for ip in found:
                try:
                    c = PGenClient(ip, timeout=3.0)
                    c.connect()
                    if c.is_alive():
                        return c
                    c.close()
                except Exception:
                    pass
            return None

        def _on_result(client):
            if client and client.connected:
                self.client = client
                self.ip_var.set(client.host)
                self._on_connected()
            else:
                self.status_var.set("Not found — enter IP and click Connect")

        def _worker():
            result = _try_connect()
            self.after(0, _on_result, result)

        threading.Thread(target=_worker, daemon=True).start()

    def _connect(self):
        ip = self.ip_var.get().strip()
        if not ip:
            messagebox.showwarning("Connect", "Enter an IP address.")
            return
        self.status_var.set(f"Connecting to {ip}...")
        self.update_idletasks()

        def _worker():
            try:
                c = PGenClient(ip, timeout=3.0)
                c.connect()
                if c.is_alive():
                    self.client = c
                    self.after(0, self._on_connected)
                else:
                    c.close()
                    self.after(0, lambda: self.status_var.set(
                        f"No response from {ip}"))
            except Exception as e:
                self.after(0, lambda: self.status_var.set(
                    f"Failed: {e}"))

        threading.Thread(target=_worker, daemon=True).start()

    def _disconnect(self):
        if self._poll_id:
            self.after_cancel(self._poll_id)
            self._poll_id = None
        if self.client:
            try:
                self.client.close()
            except Exception:
                pass
            self.client = None
        self.status_var.set("Disconnected")
        self.connect_btn.config(state=tk.NORMAL)
        self.disconnect_btn.config(state=tk.DISABLED)

    def _on_connected(self):
        self.status_var.set(f"Connected to {self.client.host}")
        self.connect_btn.config(state=tk.DISABLED)
        self.disconnect_btn.config(state=tk.NORMAL)
        self._refresh_all()
        self._start_poll()

    def _start_poll(self):
        """Periodically check connection is alive."""
        def _check():
            if self.client:
                try:
                    if not self.client.is_alive():
                        raise ConnectionError
                except Exception:
                    self._disconnect()
                    self.status_var.set("Connection lost")
                    return
            self._poll_id = self.after(10000, _check)
        self._poll_id = self.after(10000, _check)

    def _discover(self):
        self.status_var.set("Discovering...")
        self.update_idletasks()

        def _worker():
            found = PGenClient.discover(timeout=3.0)
            self.after(0, _on_done, found)

        def _on_done(found):
            if found:
                self.ip_var.set(found[0])
                all_ips = list(set(KNOWN_IPS + found))
                self.ip_entry.config(values=all_ips)
                self.status_var.set(f"Found: {', '.join(found)}")
            else:
                self.status_var.set("No PGenerator found on network")

        threading.Thread(target=_worker, daemon=True).start()

    # ------------------------------------------------------------------
    # Refresh helpers
    # ------------------------------------------------------------------
    def _refresh_all(self):
        self._refresh_system()
        self._read_signal()
        self._read_hdr()
        self._refresh_network()

    def _refresh_system(self):
        if not self.client:
            return

        def _worker():
            info = self.client.cmd_multiple(
                "GET_PGENERATOR_VERSION", "GET_DEVICE_MODEL",
                "GET_HOSTNAME", "GET_TEMPERATURE",
                "GET_RESOLUTION", "GET_HDMI_INFO", "GET_UP_FROM")
            self.after(0, _update, info)

        def _update(info):
            mapping = {
                "version": "GET_PGENERATOR_VERSION",
                "model": "GET_DEVICE_MODEL",
                "hostname": "GET_HOSTNAME",
                "temperature": "GET_TEMPERATURE",
                "resolution": "GET_RESOLUTION",
                "hdmi_info": "GET_HDMI_INFO",
                "uptime": "GET_UP_FROM",
            }
            for field, cmd in mapping.items():
                val = info.get(cmd, "—")
                if field == "temperature" and val != "—":
                    val = f"{val} °C"
                self.sys_fields[field].set(val)

        threading.Thread(target=_worker, daemon=True).start()

    def _read_signal(self):
        if not self.client:
            return

        def _worker():
            conf = self.client.get_conf_all()
            self.after(0, _update, conf)

        def _update(conf):
            # Signal mode
            if conf.get("is_sdr") == "1":
                self.signal_mode_var.set("SDR")
            elif conf.get("is_hdr") == "1":
                eotf = conf.get("eotf", "2")
                self.signal_mode_var.set("HLG" if eotf == "3" else "HDR10")
            elif conf.get("is_ll_dovi") == "1":
                self.signal_mode_var.set("Dolby Vision LL")
            elif conf.get("is_std_dovi") == "1":
                self.signal_mode_var.set("Dolby Vision Std")
            else:
                self.signal_mode_var.set("SDR")

            # AVI InfoFrame settings
            cf = conf.get("color_format", "0")
            self.color_format_var.set(
                {"0": "0 — RGB", "1": "1 — YCbCr 444",
                 "2": "2 — YCbCr 422", "3": "3 — YCbCr 420"}.get(cf, cf))

            cl = conf.get("colorimetry", "0")
            self.colorimetry_var.set(
                {"0": "0 — BT.709", "1": "1 — BT.2020"}.get(cl, cl))

            qr = conf.get("rgb_quant_range", "2")
            self.quant_range_var.set(
                {"0": "0 — Default", "1": "1 — Limited (16-235)",
                 "2": "2 — Full (0-255)"}.get(qr, qr))

            bd = conf.get("max_bpc", "8")
            self.bit_depth_var.set(bd)

        threading.Thread(target=_worker, daemon=True).start()

    def _read_hdr(self):
        if not self.client:
            return

        def _worker():
            conf = self.client.get_conf_all()
            self.after(0, _update, conf)

        def _update(conf):
            eotf = conf.get("eotf", "2")
            self.eotf_var.set(
                {"0": "0 — SDR Gamma", "1": "1 — HDR Gamma",
                 "2": "2 — SMPTE ST.2084 (PQ)",
                 "3": "3 — HLG"}.get(eotf, eotf))

            prim = conf.get("primaries", "1")
            self.primaries_var.set(
                {"0": "0 — Custom / BT.709", "1": "1 — BT.2020 / D65",
                 "2": "2 — P3 / D65",
                 "3": "3 — P3 / DCI Theater"}.get(prim, prim))

            self.max_luma_var.set(conf.get("max_luma", "1000"))
            self.min_luma_var.set(conf.get("min_luma", "5"))
            self.max_cll_var.set(conf.get("max_cll", "1000"))
            self.max_fall_var.set(conf.get("max_fall", "250"))

            dv = conf.get("dv_status", "0")
            self.dv_status_var.set(
                {"0": "0 — Disabled", "1": "1 — Enabled"}.get(dv, dv))

            dvcs = conf.get("dv_color_space", "0")
            self.dv_cs_var.set(
                {"0": "0 — YCbCr 422 (12-bit)",
                 "1": "1 — RGB 444 (8-bit tunnel)",
                 "2": "2 — YCbCr 444 (10-bit)"}.get(dvcs, dvcs))

            dvm = conf.get("dv_metadata", "0")
            self.dv_meta_var.set(
                {"0": "0 — Type 1 (static)",
                 "1": "1 — Type 4 (dynamic)"}.get(dvm, dvm))

        threading.Thread(target=_worker, daemon=True).start()

    def _refresh_network(self):
        if not self.client:
            return

        def _worker():
            info = self.client.cmd_multiple(
                "GET_ALL_IPMAC",
                "GET_IP-ap0", "GET_MAC-ap0",
                "GET_IP-wlan0", "GET_MAC-wlan0",
                "GET_IP-eth0", "GET_MAC-eth0",
                "GET_IP-bnep", "GET_MAC-bnep",
                "GET_IP-usb0")
            self.after(0, _update, info)

        def _update(info):
            mapping = {
                "ip_ap0": "GET_IP-ap0", "mac_ap0": "GET_MAC-ap0",
                "ip_wlan0": "GET_IP-wlan0", "mac_wlan0": "GET_MAC-wlan0",
                "ip_eth0": "GET_IP-eth0", "mac_eth0": "GET_MAC-eth0",
                "ip_bnep": "GET_IP-bnep", "mac_bnep": "GET_MAC-bnep",
                "ip_usb0": "GET_IP-usb0",
            }
            for field, cmd in mapping.items():
                self.net_fields[field].set(info.get(cmd, "—"))

        threading.Thread(target=_worker, daemon=True).start()

    def _read_edid(self):
        if not self.client:
            return

        def _worker():
            edid = self.client.get_edid()
            self.after(0, _update, edid)

        def _update(edid):
            self.edid_text.delete("1.0", tk.END)
            self.edid_text.insert(tk.END, edid)

        threading.Thread(target=_worker, daemon=True).start()

    # ------------------------------------------------------------------
    # Apply helpers
    # ------------------------------------------------------------------
    def _apply_signal(self):
        if not self.client:
            return

        def _worker():
            c = self.client
            # Signal mode
            mode = self.signal_mode_var.get()
            mode_map = {
                "SDR": {"is_sdr": "1", "is_hdr": "0", "is_ll_dovi": "0",
                        "is_std_dovi": "0", "dv_status": "0"},
                "HDR10": {"is_sdr": "0", "is_hdr": "1", "is_ll_dovi": "0",
                          "is_std_dovi": "0", "dv_status": "0", "eotf": "2"},
                "HLG": {"is_sdr": "0", "is_hdr": "1", "is_ll_dovi": "0",
                        "is_std_dovi": "0", "dv_status": "0", "eotf": "3"},
                "Dolby Vision LL": {"is_sdr": "0", "is_hdr": "0",
                                    "is_ll_dovi": "1", "is_std_dovi": "0",
                                    "dv_status": "1"},
                "Dolby Vision Std": {"is_sdr": "0", "is_hdr": "0",
                                     "is_ll_dovi": "0", "is_std_dovi": "1",
                                     "dv_status": "1"},
            }
            for key, val in mode_map.get(mode, {}).items():
                c.set_conf(key, val)

            # Color format — extract number from combo value
            cf = self.color_format_var.get().split(" ")[0]
            c.set_conf("color_format", cf)

            cl = self.colorimetry_var.get().split(" ")[0]
            c.set_conf("colorimetry", cl)

            qr = self.quant_range_var.get().split(" ")[0]
            c.set_conf("rgb_quant_range", qr)

            bd = self.bit_depth_var.get()
            c.set_conf("max_bpc", bd)

            # Restart to apply infoframe changes
            c.restart_pgenerator()
            time.sleep(1)
            self.after(0, lambda: self.status_var.set("Signal settings applied"))

        threading.Thread(target=_worker, daemon=True).start()

    def _apply_hdr(self):
        if not self.client:
            return

        def _worker():
            c = self.client
            eotf = self.eotf_var.get().split(" ")[0]
            c.set_conf("eotf", eotf)

            prim = self.primaries_var.get().split(" ")[0]
            c.set_conf("primaries", prim)

            c.set_conf("max_luma", self.max_luma_var.get())
            c.set_conf("min_luma", self.min_luma_var.get())
            c.set_conf("max_cll", self.max_cll_var.get())
            c.set_conf("max_fall", self.max_fall_var.get())

            dv = self.dv_status_var.get().split(" ")[0]
            c.set_conf("dv_status", dv)

            dvcs = self.dv_cs_var.get().split(" ")[0]
            c.set_conf("dv_color_space", dvcs)

            dvm = self.dv_meta_var.get().split(" ")[0]
            c.set_conf("dv_metadata", dvm)

            c.restart_pgenerator()
            time.sleep(1)
            self.after(0, lambda: self.status_var.set("HDR/DV settings applied"))

        threading.Thread(target=_worker, daemon=True).start()

    def _send_pattern(self):
        if not self.client:
            return
        draw = self.pat_draw_var.get()
        w = self.pat_w_var.get()
        h = self.pat_h_var.get()
        res = self.pat_res_var.get()
        r = self.pat_red_var.get()
        g = self.pat_green_var.get()
        b = self.pat_blue_var.get()
        bg = self.pat_bg_var.get()
        dim = f"{w},{h}"
        rgb = f"{r},{g},{b}"

        def _worker():
            self.client.send_rgb(draw, dim, res, rgb, bg)
            self.after(0, lambda: self.status_var.set("Pattern sent"))

        threading.Thread(target=_worker, daemon=True).start()

    def _update_color_preview(self):
        try:
            r = self.pat_red_var.get()
            g = self.pat_green_var.get()
            b = self.pat_blue_var.get()
            color = f"#{r:02x}{g:02x}{b:02x}"
            self.color_preview.config(bg=color)
        except Exception:
            pass

    # ------------------------------------------------------------------
    # System actions
    # ------------------------------------------------------------------
    def _restart_pg(self):
        if not self.client:
            return
        if messagebox.askyesno("Restart", "Restart PGenerator software?"):
            def _worker():
                self.client.restart_pgenerator()
                time.sleep(2)
                self.after(0, self._refresh_system)
            threading.Thread(target=_worker, daemon=True).start()

    def _reboot(self):
        if not self.client:
            return
        if messagebox.askyesno("Reboot",
                               "Reboot the PGenerator device?\n"
                               "Connection will be lost."):
            try:
                self.client.reboot()
            except Exception:
                pass
            self._disconnect()

    # ------------------------------------------------------------------
    # Cleanup
    # ------------------------------------------------------------------
    def _on_close(self):
        self._disconnect()
        self.destroy()


# ===========================================================================
# Entry point
# ===========================================================================
def main():
    app = PgenCompanionApp()
    app.mainloop()


if __name__ == "__main__":
    main()
