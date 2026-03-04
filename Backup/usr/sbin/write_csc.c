/*
 * Setuid-root helper to write HDMI CSC registers on BCM2711.
 * Called by drm_override.so to fix RGB→YCbCr conversion.
 *
 * Usage: write_csc bt709|bt2020
 *
 * The CSC_CTL ORDER field is 3 (RBG), meaning:
 *   - Columns (inputs):  in1=R, in2=B, in3=G
 *   - Rows (outputs):    out1→R/Cr wire, out2→B/Cb wire, out3→G/Y wire
 * Matrix rows are [Cr, Cb, Y] with columns [R, B, G].
 *
 * Cross-compile:
 *   arm-linux-gnueabihf-gcc -static -o write_csc write_csc.c
 * Install:
 *   install -m 4755 -o root write_csc /usr/sbin/write_csc
 */
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdint.h>
#include <string.h>

#define CSC_BASE  0xFEF00200
#define PAGE_SIZE 4096

/* BT.709 RGB→YCbCr limited range (RBG column/row order) */
static const uint32_t csc_bt709[6] = {
    0xFEB70E00, 0x2000F349, 0x0E00FCCB,
    0x2000F535, 0x01FA05D2, 0x04001394
};

/* BT.2020 RGB→YCbCr limited range (RBG column/row order) */
static const uint32_t csc_bt2020[6] = {
    0xFEE00E00, 0x2000F320, 0x0E00FC17,
    0x2000F5E9, 0x01A00731, 0x0400128F
};

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: write_csc bt709|bt2020\n");
        return 1;
    }

    const uint32_t *matrix;
    if (strcmp(argv[1], "bt709") == 0)
        matrix = csc_bt709;
    else if (strcmp(argv[1], "bt2020") == 0)
        matrix = csc_bt2020;
    else {
        fprintf(stderr, "Unknown colorimetry: %s\n", argv[1]);
        return 1;
    }

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }

    unsigned long page = CSC_BASE & ~((unsigned long)(PAGE_SIZE - 1));
    unsigned long offset = CSC_BASE - page;

    volatile uint32_t *map = mmap(NULL, PAGE_SIZE, PROT_READ | PROT_WRITE,
                                   MAP_SHARED, fd, page);
    close(fd);
    if (map == MAP_FAILED) { perror("mmap"); return 1; }

    volatile uint32_t *csc = (volatile uint32_t *)((char *)map + offset);

    /* Write 6 coefficient registers, leave CSC_CTL untouched */
    int i;
    for (i = 0; i < 6; i++) {
        csc[i + 1] = matrix[i];
    }

    munmap((void *)map, PAGE_SIZE);
    return 0;
}
