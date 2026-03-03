/*
 * SCDC tool — uses raw syscalls, no glibc dependency.
 *
 * arm-linux-gnueabihf-gcc -static -o scdc_tool scdc_tool.c
 */
#include <stdint.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <fcntl.h>
#include <string.h>

/* I2C definitions */
#define I2C_RDWR 0x0707
#define I2C_M_RD 0x0001

struct i2c_msg {
    uint16_t addr;
    uint16_t flags;
    uint16_t len;
    uint8_t *buf;
};

struct i2c_rdwr_ioctl_data {
    struct i2c_msg *msgs;
    uint32_t nmsgs;
};

#define SCDC_ADDR 0x54

static inline long raw_ioctl(int fd, unsigned long req, void *arg) {
    return syscall(SYS_ioctl, fd, req, arg);
}

static void wr(const char *s) { write(2, s, strlen(s)); }

static void wr_hex(unsigned char val) {
    char hex[5] = "0x00";
    const char *h = "0123456789abcdef";
    hex[2] = h[(val >> 4) & 0xf];
    hex[3] = h[val & 0xf];
    wr(hex);
}

static void wr_dec(unsigned int val) {
    char buf[12];
    int i = 0;
    if (val == 0) { wr("0"); return; }
    while (val > 0) { buf[i++] = '0' + (val % 10); val /= 10; }
    char out[12];
    for (int j = 0; j < i; j++) out[j] = buf[i - 1 - j];
    out[i] = 0;
    wr(out);
}

static int scdc_read(int fd, unsigned char reg, unsigned char *val) {
    struct i2c_msg msgs[2];
    struct i2c_rdwr_ioctl_data data;
    msgs[0].addr = SCDC_ADDR;
    msgs[0].flags = 0;
    msgs[0].len = 1;
    msgs[0].buf = &reg;
    msgs[1].addr = SCDC_ADDR;
    msgs[1].flags = I2C_M_RD;
    msgs[1].len = 1;
    msgs[1].buf = val;
    data.msgs = msgs;
    data.nmsgs = 2;
    return raw_ioctl(fd, I2C_RDWR, &data) < 0 ? -1 : 0;
}

static int scdc_write(int fd, unsigned char reg, unsigned char val) {
    unsigned char buf[2] = { reg, val };
    struct i2c_msg msg;
    struct i2c_rdwr_ioctl_data data;
    msg.addr = SCDC_ADDR;
    msg.flags = 0;
    msg.len = 2;
    msg.buf = buf;
    data.msgs = &msg;
    data.nmsgs = 1;
    return raw_ioctl(fd, I2C_RDWR, &data) < 0 ? -1 : 0;
}

static void dump(int fd) {
    unsigned char v;
    wr("SCDC Register Dump (addr 0x54)\n");
    wr("==============================\n");

    if (scdc_read(fd, 0x01, &v) == 0) {
        wr("  Sink Version    [0x01]: "); wr_hex(v);
        if (v == 1) wr(" (HDMI 2.0)");
        wr("\n");
    } else wr("  Sink Version: READ FAILED (no SCDC support?)\n");

    if (scdc_read(fd, 0x02, &v) == 0) {
        wr("  Source Version  [0x02]: "); wr_hex(v); wr("\n");
    }

    if (scdc_read(fd, 0x10, &v) == 0) {
        wr("  Update_0        [0x10]: "); wr_hex(v);
        wr(" StatusUpd="); wr_dec(v & 1);
        wr(" CEDUpd="); wr_dec((v >> 1) & 1);
        wr("\n");
    }

    if (scdc_read(fd, 0x20, &v) == 0) {
        wr("  TMDS_Config     [0x20]: "); wr_hex(v);
        wr(" ScrambleEn="); wr_dec(v & 1);
        wr(" TMDS_BitClkRatio="); wr_dec((v >> 1) & 1);
        wr("\n");
    }

    if (scdc_read(fd, 0x21, &v) == 0) {
        wr("  Scrambler_Status[0x21]: "); wr_hex(v);
        wr(" ScrambleActive="); wr_dec(v & 1);
        wr("\n");
    }

    if (scdc_read(fd, 0x30, &v) == 0) {
        wr("  Config_0        [0x30]: "); wr_hex(v);
        wr(" RR_Enable="); wr_dec(v & 1);
        wr("\n");
    }

    if (scdc_read(fd, 0x40, &v) == 0) {
        wr("  Status_Flags_0  [0x40]: "); wr_hex(v);
        wr(" ClkDet="); wr_dec(v & 1);
        wr(" Ch0Lock="); wr_dec((v >> 1) & 1);
        wr(" Ch1Lock="); wr_dec((v >> 2) & 1);
        wr(" Ch2Lock="); wr_dec((v >> 3) & 1);
        wr("\n");
    }

    /* Character error detection */
    wr("  Character Error Detection:\n");
    unsigned char el, eh;
    int ch;
    for (ch = 0; ch < 3; ch++) {
        if (scdc_read(fd, 0x50 + ch * 2, &el) == 0 &&
            scdc_read(fd, 0x51 + ch * 2, &eh) == 0) {
            unsigned int err = ((eh & 0x7f) << 8) | el;
            wr("    Ch"); wr_dec(ch); wr(": errors="); wr_dec(err);
            wr(" valid="); wr_dec((eh >> 7) & 1);
            wr("\n");
        }
    }
}

static unsigned char hexval(const char *s) {
    unsigned char v = 0;
    const char *p = s;
    if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) p += 2;
    while (*p) {
        v <<= 4;
        if (*p >= '0' && *p <= '9') v |= *p - '0';
        else if (*p >= 'a' && *p <= 'f') v |= *p - 'a' + 10;
        else if (*p >= 'A' && *p <= 'F') v |= *p - 'A' + 10;
        p++;
    }
    return v;
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        wr("Usage: scdc_tool <bus#> dump|read|write|scramble\n");
        wr("  scdc_tool 21 dump\n");
        wr("  scdc_tool 21 read 0x20\n");
        wr("  scdc_tool 21 write 0x20 0x03\n");
        wr("  scdc_tool 21 scramble 1\n");
        return 1;
    }

    char path[32] = "/dev/i2c-";
    int plen = 9, alen = strlen(argv[1]);
    int i;
    for (i = 0; i < alen && plen < 30; i++) path[plen++] = argv[1][i];
    path[plen] = 0;

    int fd = open(path, O_RDWR);
    if (fd < 0) { wr("Failed to open "); wr(path); wr("\n"); return 1; }

    if (strcmp(argv[2], "dump") == 0) {
        dump(fd);
    } else if (strcmp(argv[2], "read") == 0 && argc >= 4) {
        unsigned char reg = hexval(argv[3]);
        unsigned char val;
        if (scdc_read(fd, reg, &val) == 0) {
            wr("Reg "); wr_hex(reg); wr(" = "); wr_hex(val); wr("\n");
        } else wr("Read failed\n");
    } else if (strcmp(argv[2], "write") == 0 && argc >= 5) {
        unsigned char reg = hexval(argv[3]);
        unsigned char val = hexval(argv[4]);
        if (scdc_write(fd, reg, val) == 0) {
            wr("Wrote "); wr_hex(val); wr(" to reg "); wr_hex(reg); wr("\n");
        } else wr("Write failed\n");
    } else if (strcmp(argv[2], "scramble") == 0 && argc >= 4) {
        int enable = argv[3][0] == '1';
        unsigned char tmds_cfg = enable ? 0x03 : 0x00;
        wr(enable ? "Enabling" : "Disabling");
        wr(" TMDS scrambling (TMDS_Config=");
        wr_hex(tmds_cfg);
        wr(")\n");
        if (scdc_write(fd, 0x20, tmds_cfg) == 0) {
            unsigned char rb;
            wr("  Write OK\n");
            if (scdc_read(fd, 0x20, &rb) == 0) {
                wr("  Readback: "); wr_hex(rb); wr("\n");
            }
            usleep(200000);
            if (scdc_read(fd, 0x21, &rb) == 0) {
                wr("  Scrambler_Status: "); wr_hex(rb);
                wr(" (active="); wr_dec(rb & 1); wr(")\n");
            }
        } else wr("  Write failed\n");
    }

    close(fd);
    return 0;
}
