/*
 * disable_csc — Tiny setuid helper to bypass the BCM2711 HDMI CSC.
 *
 * Clears bit 0 (enable) of the CSC_CTL register at physical address
 * 0xFEF00200, disabling the hardware Color Space Converter in the
 * HDMI0 encoder so pixel values pass through unchanged.
 *
 * Called by drm_override.so (running inside PGeneratord as user
 * pgenerator) after each DRM atomic modeset to prevent the vc4
 * kernel driver's CSC from double-converting pattern values.
 *
 * Uses raw syscalls to avoid glibc version dependency (Pi has 2.21).
 *
 * Must be installed setuid root:
 *   chown root:root /usr/sbin/disable_csc
 *   chmod 4755 /usr/sbin/disable_csc
 *
 * Cross-compile:
 *   arm-linux-gnueabihf-gcc -O2 -nostdlib -o disable_csc disable_csc.c
 */
#include <stdint.h>

/* Raw syscall wrappers — no glibc dependency */
static inline long raw_syscall2(long nr, long a0, long a1) {
    register long r7 __asm__("r7") = nr;
    register long r0 __asm__("r0") = a0;
    register long r1 __asm__("r1") = a1;
    __asm__ volatile("svc 0" : "+r"(r0) : "r"(r7), "r"(r1) : "memory");
    return r0;
}
static inline long raw_syscall6(long nr, long a0, long a1, long a2,
                                long a3, long a4, long a5) {
    register long r7 __asm__("r7") = nr;
    register long r0 __asm__("r0") = a0;
    register long r1 __asm__("r1") = a1;
    register long r2 __asm__("r2") = a2;
    register long r3 __asm__("r3") = a3;
    register long r4 __asm__("r4") = a4;
    register long r5 __asm__("r5") = a5;
    __asm__ volatile("svc 0" : "+r"(r0)
                     : "r"(r7), "r"(r1), "r"(r2), "r"(r3), "r"(r4), "r"(r5)
                     : "memory");
    return r0;
}

/* ARM syscall numbers */
#define SYS_exit    1
#define SYS_open    5
#define SYS_close   6
#define SYS_mmap2   192   /* mmap2: offset in pages (4096-byte units) */
#define SYS_munmap  91

#define O_RDWR      2
#define O_SYNC      0x101000
#define PROT_RW     3     /* PROT_READ | PROT_WRITE */
#define MAP_SHARED  1

#define CSC_CTL_PHYS  0xFEF00200
#define PAGE_SIZE     4096

void _start(void) {
    static const char path[] = "/dev/mem";
    int fd = (int)raw_syscall2(SYS_open, (long)path, O_RDWR | O_SYNC);
    if (fd < 0) raw_syscall2(SYS_exit, 1, 0);

    /* mmap2 offset is in pages */
    long page_off = (CSC_CTL_PHYS & ~(PAGE_SIZE - 1)) / PAGE_SIZE;
    volatile uint32_t *map = (volatile uint32_t *)raw_syscall6(
        SYS_mmap2, 0, PAGE_SIZE, PROT_RW, MAP_SHARED, fd, page_off);

    raw_syscall2(SYS_close, fd, 0);

    /* mmap2 returns -errno on error (values 0xFFFFF000..0xFFFFFFFF).
     * Valid addresses can be >= 0x80000000, so don't use signed check. */
    if ((unsigned long)map > 0xFFFFF000UL)
        raw_syscall2(SYS_exit, 2, 0);

    volatile uint32_t *csc_ctl = map + ((CSC_CTL_PHYS & (PAGE_SIZE - 1)) / 4);
    uint32_t val = *csc_ctl;
    if (val & 1) {
        *csc_ctl = val & ~(uint32_t)1;
    }

    raw_syscall2(SYS_munmap, (long)map, PAGE_SIZE);
    raw_syscall2(SYS_exit, 0, 0);
    __builtin_unreachable();
}
