#!/usr/bin/python
# -*- coding: utf-8 -*-
"""
drm_hdr_set.py — Pre-set DRM connector properties for HDR before
                  the PGeneratord binary starts.

Sets max_bpc, Colorimetry, and HDR_OUTPUT_METADATA blob on the first
connected HDMI connector using Python2 ctypes + DRM ioctls.

Usage:  drm_hdr_set.py [/etc/PGenerator/PGenerator.conf]
"""

import sys
import os
import struct
import ctypes
import ctypes.util

# ──────── DRM ioctl definitions ────────
# From linux/drm.h and linux/drm_mode.h

DRM_IOCTL_BASE = ord('d')

def _IOC(dir_, type_, nr, size):
    return (dir_ << 30) | (type_ << 8) | nr | (size << 16)

_IOC_WRITE = 1
_IOC_READ  = 2
_IOC_NONE  = 0

def _IO(type_, nr):
    return _IOC(_IOC_NONE, type_, nr, 0)

def _IOW(type_, nr, size):
    return _IOC(_IOC_WRITE, type_, nr, size)

def _IOR(type_, nr, size):
    return _IOC(_IOC_READ, type_, nr, size)

def _IOWR(type_, nr, size):
    return _IOC(_IOC_READ | _IOC_WRITE, type_, nr, size)

# DRM ioctls we need
DRM_IOCTL_SET_CLIENT_CAP = _IOW(DRM_IOCTL_BASE, 0x0D, 16)  # struct drm_set_client_cap
DRM_IOCTL_MODE_GETRESOURCES = _IOWR(DRM_IOCTL_BASE, 0xA0, 64)
DRM_IOCTL_MODE_GETCONNECTOR = _IOWR(DRM_IOCTL_BASE, 0xA7, 76)
DRM_IOCTL_MODE_GETPROPERTY = _IOWR(DRM_IOCTL_BASE, 0xAA, 60)
DRM_IOCTL_MODE_OBJ_GETPROPERTIES = _IOWR(DRM_IOCTL_BASE, 0xB9, 24)
DRM_IOCTL_MODE_OBJ_SETPROPERTY = _IOWR(DRM_IOCTL_BASE, 0xBA, 20)
DRM_IOCTL_MODE_CREATEPROPBLOB = _IOWR(DRM_IOCTL_BASE, 0xBD, 16)
DRM_IOCTL_MODE_DESTROYPROPBLOB = _IOWR(DRM_IOCTL_BASE, 0xBE, 4)
DRM_IOCTL_MODE_ATOMIC = _IOWR(DRM_IOCTL_BASE, 0xBC, 56)

DRM_CLIENT_CAP_ATOMIC = 3
DRM_MODE_OBJECT_CONNECTOR = 0xc0c0c0c0

DRM_MODE_ATOMIC_TEST_ONLY = 0x0100
DRM_MODE_ATOMIC_NONBLOCK  = 0x0200
DRM_MODE_ATOMIC_ALLOW_MODESET = 0x0400

# Connector types
DRM_MODE_CONNECTOR_HDMIA = 11
DRM_MODE_CONNECTOR_HDMIB = 12

# ──────── libc for ioctl ────────
libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)

def drm_ioctl(fd, request, arg_buf):
    """Perform ioctl and return 0 on success, -errno on failure."""
    buf = ctypes.create_string_buffer(arg_buf)
    ret = libc.ioctl(fd, ctypes.c_ulong(request), buf)
    if ret < 0:
        return -ctypes.get_errno(), buf.raw
    return 0, buf.raw

# ──────── Config parser ────────
def parse_conf(path):
    cfg = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if '=' in line and not line.startswith('#'):
                    k, v = line.split('=', 1)
                    cfg[k.strip()] = v.strip()
    except IOError:
        pass
    return cfg

def conf_int(cfg, key, default=0):
    try:
        return int(cfg.get(key, default))
    except (ValueError, TypeError):
        return default

def conf_float(cfg, key, default=0.0):
    try:
        return float(cfg.get(key, default))
    except (ValueError, TypeError):
        return default

# ──────── DRM helpers ────────
def get_resources(fd):
    """Get connector IDs from DRM."""
    # First call to get counts
    buf = struct.pack("IIIIIIIIII", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    # drm_mode_card_res: fb_id_ptr(8), crtc_id_ptr(8), connector_id_ptr(8),
    #   encoder_id_ptr(8), count_fbs(4), count_crtcs(4), count_connectors(4),
    #   count_encoders(4), min_w(4), max_w(4), min_h(4), max_h(4)
    buf = b'\x00' * 64
    ret, data = drm_ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, buf)
    if ret < 0:
        return []

    # Parse counts
    count_fbs, count_crtcs, count_conns, count_encs = struct.unpack_from("IIII", data, 32)

    # Allocate arrays
    conn_arr = (ctypes.c_uint32 * count_conns)()

    # Pack with pointers
    buf = struct.pack("QQQQ",
        0,  # fb_id_ptr
        0,  # crtc_id_ptr
        ctypes.addressof(conn_arr),  # connector_id_ptr
        0   # encoder_id_ptr
    )
    buf += struct.pack("IIII", 0, 0, count_conns, 0)
    buf += b'\x00' * 16  # min/max w/h

    ret, data = drm_ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, buf)
    if ret < 0:
        return []

    return list(conn_arr)

def get_connector_info(fd, conn_id):
    """Get connector type and connection status."""
    # drm_mode_get_connector structure (simplified)
    # We need: encoders_ptr(8), modes_ptr(8), props_ptr(8), prop_values_ptr(8),
    #   count_modes(4), count_props(4), count_encoders(4),
    #   encoder_id(4), connector_id(4), connector_type(4),
    #   connector_type_id(4), connection(4), mm_width(4), mm_height(4),
    #   subpixel(4), pad(4)
    buf = struct.pack("QQQQ", 0, 0, 0, 0)  # pointers
    buf += struct.pack("III", 0, 0, 0)  # counts
    buf += struct.pack("IIIII", 0, conn_id, 0, 0, 0)  # encoder, conn_id, type, type_id, connection
    buf += struct.pack("III", 0, 0, 0)  # mm_w, mm_h, subpixel
    buf += b'\x00' * 4  # pad

    ret, data = drm_ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, buf)
    if ret < 0:
        return None, None

    # Parse connector_type and connection status
    offset = 32 + 12 + 4  # after pointers(32) + counts(12) + encoder_id(4)
    conn_id_r, conn_type, conn_type_id, connection = struct.unpack_from("IIII", data, offset)
    return conn_type, connection

def get_object_properties(fd, obj_id, obj_type):
    """Get all property IDs and values for an object."""
    # drm_mode_obj_get_properties: props_ptr(8), prop_values_ptr(8),
    #   count_props(4), obj_id(4), obj_type(4)
    buf = struct.pack("QQ", 0, 0) + struct.pack("III", 0, obj_id, obj_type)
    ret, data = drm_ioctl(fd, DRM_IOCTL_MODE_OBJ_GETPROPERTIES, buf)
    if ret < 0:
        return {}

    count = struct.unpack_from("I", data, 16)[0]
    if count == 0:
        return {}

    prop_ids = (ctypes.c_uint32 * count)()
    prop_vals = (ctypes.c_uint64 * count)()

    buf = struct.pack("QQ", ctypes.addressof(prop_ids), ctypes.addressof(prop_vals))
    buf += struct.pack("III", count, obj_id, obj_type)
    ret, data = drm_ioctl(fd, DRM_IOCTL_MODE_OBJ_GETPROPERTIES, buf)
    if ret < 0:
        return {}

    return dict(zip(list(prop_ids), list(prop_vals)))

def get_property_name(fd, prop_id):
    """Get property name by ID."""
    # drm_mode_get_property: values_ptr(8), enum_blob_ptr(8), prop_id(4),
    #   flags(4), name[32], count_values(4), count_enum_blobs(4)
    buf = struct.pack("QQ", 0, 0)  # pointers
    buf += struct.pack("II", prop_id, 0)  # prop_id, flags
    buf += b'\x00' * 32  # name
    buf += struct.pack("II", 0, 0)  # counts

    ret, data = drm_ioctl(fd, DRM_IOCTL_MODE_GETPROPERTY, buf)
    if ret < 0:
        return ""

    name_bytes = data[24:56]
    return name_bytes.split(b'\x00')[0].decode('ascii', errors='ignore')

def set_object_property(fd, obj_id, obj_type, prop_id, value):
    """Set a single property value."""
    # drm_mode_obj_set_property: value(8), prop_id(4), obj_id(4), obj_type(4)
    buf = struct.pack("QIII", value, prop_id, obj_id, obj_type)
    ret, _ = drm_ioctl(fd, DRM_IOCTL_MODE_OBJ_SETPROPERTY, buf)
    return ret

def create_property_blob(fd, data_bytes):
    """Create a property blob, return blob_id."""
    data_buf = ctypes.create_string_buffer(data_bytes, len(data_bytes))
    # drm_mode_create_blob: data(8), length(4), blob_id(4)
    buf = struct.pack("QII", ctypes.addressof(data_buf), len(data_bytes), 0)
    ret, out = drm_ioctl(fd, DRM_IOCTL_MODE_CREATEPROPBLOB, buf)
    if ret < 0:
        return 0
    blob_id = struct.unpack_from("I", out, 12)[0]
    return blob_id

def set_client_cap(fd, cap, value):
    """Set a DRM client capability."""
    buf = struct.pack("QQ", cap, value)
    ret, _ = drm_ioctl(fd, DRM_IOCTL_SET_CLIENT_CAP, buf)
    return ret

def atomic_commit(fd, obj_id, props_dict, flags=0):
    """Do an atomic commit setting properties on one object.
    props_dict: {prop_id: value, ...}
    """
    count_objs = 1
    count = len(props_dict)
    if count == 0:
        return 0

    objs_arr = (ctypes.c_uint32 * 1)(obj_id)
    count_props_arr = (ctypes.c_uint32 * 1)(count)
    props_arr = (ctypes.c_uint32 * count)(*list(props_dict.keys()))
    values_arr = (ctypes.c_uint64 * count)(*list(props_dict.values()))

    # struct drm_mode_atomic: flags(4), count_objs(4),
    #   objs_ptr(8), count_props_ptr(8), props_ptr(8),
    #   prop_values_ptr(8), reserved(8), user_data(8)
    buf = struct.pack("II", flags, count_objs)
    buf += struct.pack("Q", ctypes.addressof(objs_arr))
    buf += struct.pack("Q", ctypes.addressof(count_props_arr))
    buf += struct.pack("Q", ctypes.addressof(props_arr))
    buf += struct.pack("Q", ctypes.addressof(values_arr))
    buf += struct.pack("QQ", 0, 0)  # reserved, user_data

    ret, _ = drm_ioctl(fd, DRM_IOCTL_MODE_ATOMIC, buf)
    return ret

# ──────── HDR metadata builder ────────
# BT.2020 primaries (CIE × 50000)
PRIMARIES = {
    1: {  # BT.2020
        'gx': 8500, 'gy': 39850,
        'bx': 6550, 'by': 2300,
        'rx': 35400, 'ry': 14600,
    },
    2: {  # DCI-P3 D65
        'gx': 13250, 'gy': 34500,
        'bx': 7500,  'by': 3000,
        'rx': 34000, 'ry': 16000,
    },
    0: {  # BT.709
        'gx': 15000, 'gy': 30000,
        'bx': 7500,  'by': 3000,
        'rx': 32000, 'ry': 16500,
    },
}
WP_X = 15635  # D65
WP_Y = 16450

def build_hdr_metadata(eotf, primaries, min_luma, max_luma, max_cll, max_fall):
    """Build struct hdr_output_metadata blob."""
    prim = PRIMARIES.get(primaries, PRIMARIES[1])
    min_luma_raw = int(min_luma * 10000)  # 0.0001 cd/m² units

    # struct hdr_output_metadata {
    #   __u32 metadata_type;   // 0 = Type 1
    #   struct hdr_metadata_infoframe {
    #     __u8 eotf;
    #     __u8 metadata_type;
    #     struct { __u16 x, y; } display_primaries[3];  // G, B, R
    #     struct { __u16 x, y; } white_point;
    #     __u16 max_display_mastering_luminance;
    #     __u16 min_display_mastering_luminance;
    #     __u16 max_cll;
    #     __u16 max_fall;
    #   };
    # };
    blob = struct.pack("<I", 0)  # metadata_type = 0
    blob += struct.pack("<BB", eotf, 0)  # eotf, metadata_type
    blob += struct.pack("<HH", prim['gx'], prim['gy'])  # Green
    blob += struct.pack("<HH", prim['bx'], prim['by'])  # Blue
    blob += struct.pack("<HH", prim['rx'], prim['ry'])  # Red
    blob += struct.pack("<HH", WP_X, WP_Y)  # White point
    blob += struct.pack("<H", max_luma)
    blob += struct.pack("<H", min_luma_raw)
    blob += struct.pack("<H", max_cll)
    blob += struct.pack("<H", max_fall)
    return blob

# ──────── Main ────────
def main():
    conf_path = "/etc/PGenerator/PGenerator.conf"
    if len(sys.argv) > 1:
        conf_path = sys.argv[1]

    cfg = parse_conf(conf_path)
    is_hdr      = conf_int(cfg, "is_hdr", 0)
    eotf        = conf_int(cfg, "eotf", 0)
    colorimetry = conf_int(cfg, "colorimetry", 0)
    max_bpc     = conf_int(cfg, "max_bpc", 8)
    primaries   = conf_int(cfg, "primaries", 1)
    min_luma    = conf_float(cfg, "min_luma", 0.0)
    max_luma    = conf_int(cfg, "max_luma", 1000)
    max_cll     = conf_int(cfg, "max_cll", 1000)
    max_fall    = conf_int(cfg, "max_fall", 400)

    # Open DRM device
    fd = -1
    for card in ["/dev/dri/card1", "/dev/dri/card0"]:
        try:
            fd = os.open(card, os.O_RDWR)
            conns = get_resources(fd)
            if conns:
                break
            os.close(fd)
            fd = -1
        except OSError:
            pass

    if fd < 0:
        sys.stderr.write("drm_hdr_set: cannot open DRM device\n")
        return 1

    # Find connected HDMI connector
    conn_id = 0
    for cid in conns:
        ctype, cstatus = get_connector_info(fd, cid)
        if ctype in (DRM_MODE_CONNECTOR_HDMIA, DRM_MODE_CONNECTOR_HDMIB) and cstatus == 1:
            conn_id = cid
            break

    if not conn_id:
        sys.stderr.write("drm_hdr_set: no connected HDMI connector\n")
        os.close(fd)
        return 1

    # Get properties and build name→id map
    props = get_object_properties(fd, conn_id, DRM_MODE_OBJECT_CONNECTOR)
    name_to_id = {}
    for pid in props:
        name = get_property_name(fd, pid)
        if name:
            name_to_id[name] = pid

    # Set max_bpc
    pid_max_bpc = name_to_id.get("max bpc")
    if pid_max_bpc:
        ret = set_object_property(fd, conn_id, DRM_MODE_OBJECT_CONNECTOR,
                                  pid_max_bpc, max_bpc)
        if ret == 0:
            sys.stderr.write("drm_hdr_set: max_bpc=%d on connector %d\n" % (max_bpc, conn_id))
        else:
            sys.stderr.write("drm_hdr_set: failed max_bpc (err=%d)\n" % ret)

    # Set Colorimetry
    pid_color = name_to_id.get("Colorimetry")
    if pid_color:
        ret = set_object_property(fd, conn_id, DRM_MODE_OBJECT_CONNECTOR,
                                  pid_color, colorimetry)
        if ret == 0:
            sys.stderr.write("drm_hdr_set: colorimetry=%d\n" % colorimetry)
        else:
            sys.stderr.write("drm_hdr_set: failed colorimetry (err=%d)\n" % ret)

    # Set HDR_OUTPUT_METADATA via atomic commit (blob props need atomic API)
    pid_hdr = name_to_id.get("HDR_OUTPUT_METADATA")
    if pid_hdr:
        # Enable atomic client cap
        cap_ret = set_client_cap(fd, DRM_CLIENT_CAP_ATOMIC, 1)
        if cap_ret < 0:
            sys.stderr.write("drm_hdr_set: atomic cap not available (err=%d), "
                             "skipping HDR blob\n" % cap_ret)
        elif is_hdr and eotf > 0:
            blob_data = build_hdr_metadata(eotf, primaries, min_luma,
                                           max_luma, max_cll, max_fall)
            blob_id = create_property_blob(fd, blob_data)
            if blob_id:
                # Try atomic commit with ALL properties at once
                atomic_props = {pid_hdr: blob_id}
                if pid_max_bpc:
                    atomic_props[pid_max_bpc] = max_bpc
                if pid_color:
                    atomic_props[pid_color] = colorimetry
                # Test first
                ret = atomic_commit(fd, conn_id, atomic_props,
                    DRM_MODE_ATOMIC_TEST_ONLY | DRM_MODE_ATOMIC_ALLOW_MODESET)
                if ret == 0:
                    ret = atomic_commit(fd, conn_id, atomic_props,
                        DRM_MODE_ATOMIC_ALLOW_MODESET)
                if ret == 0:
                    sys.stderr.write("drm_hdr_set: HDR blob=%d eotf=%d prim=%d "
                        "maxL=%d minL=%.4f maxCLL=%d maxFALL=%d (atomic)\n" %
                        (blob_id, eotf, primaries, max_luma, min_luma,
                         max_cll, max_fall))
                else:
                    sys.stderr.write("drm_hdr_set: atomic HDR commit failed "
                        "(err=%d), trying legacy\n" % ret)
                    # Fallback: try legacy set
                    ret = set_object_property(fd, conn_id,
                        DRM_MODE_OBJECT_CONNECTOR, pid_hdr, blob_id)
                    if ret == 0:
                        sys.stderr.write("drm_hdr_set: HDR blob set via legacy\n")
                    else:
                        sys.stderr.write("drm_hdr_set: HDR blob legacy also "
                            "failed (err=%d)\n" % ret)
            else:
                sys.stderr.write("drm_hdr_set: failed to create HDR blob\n")
        else:
            # SDR — clear HDR metadata
            atomic_props = {pid_hdr: 0}
            ret = atomic_commit(fd, conn_id, atomic_props,
                DRM_MODE_ATOMIC_ALLOW_MODESET)
            if ret == 0:
                sys.stderr.write("drm_hdr_set: cleared HDR metadata (SDR) atomic\n")
            else:
                set_object_property(fd, conn_id, DRM_MODE_OBJECT_CONNECTOR,
                                    pid_hdr, 0)
                sys.stderr.write("drm_hdr_set: cleared HDR metadata (SDR) legacy\n")

    os.close(fd)
    sys.stderr.write("drm_hdr_set: done\n")
    return 0

if __name__ == "__main__":
    sys.exit(main())
