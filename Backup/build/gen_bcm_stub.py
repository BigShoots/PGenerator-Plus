#!/usr/bin/env python3
"""Generate a minimal ARM32 ELF shared library (libbcm_host_stub.so)
that stubs out bcm_host_init() and vc_dispmanx_* functions as no-ops.

The stub makes bcm_host_init() return immediately (void) and all
vc_dispmanx_* functions return 0 (failure handle or success for close).
This allows PGeneratord to survive the bcm_host_init call on full KMS
and proceed to its DRM/GBM code path.
"""

import struct
import os

# ARM instructions (little-endian)
ARM_BX_LR = 0xE12FFF1E       # bx lr (return void)
ARM_MOV_R0_0_BX_LR = bytes([
    0x00, 0x00, 0xA0, 0xE3,  # mov r0, #0
    0x1E, 0xFF, 0x2F, 0xE1,  # bx lr
])
ARM_MVN_R0_0_BX_LR = bytes([
    0x00, 0x00, 0xE0, 0xE3,  # mvn r0, #0  (r0 = -1)
    0x1E, 0xFF, 0x2F, 0xE1,  # bx lr
])
ARM_RETURN_VOID = struct.pack('<I', ARM_BX_LR)  # 4 bytes

# Function stubs: (name, code_bytes)
# void functions get just "bx lr"
# functions returning 0 get "mov r0, #0; bx lr"
# functions returning -1 get "mvn r0, #0; bx lr"
stubs = [
    ("bcm_host_init",                         ARM_RETURN_VOID),      # void
    ("bcm_host_deinit",                       ARM_RETURN_VOID),      # void
    ("vc_dispmanx_display_open",              ARM_MOV_R0_0_BX_LR),  # returns 0 (fail)
    ("vc_dispmanx_display_close",             ARM_MOV_R0_0_BX_LR),  # returns 0
    ("vc_dispmanx_display_get_info",          ARM_MVN_R0_0_BX_LR),  # returns -1
    ("vc_dispmanx_display_set_background",    ARM_MVN_R0_0_BX_LR),  # returns -1
    ("vc_dispmanx_update_start",              ARM_MOV_R0_0_BX_LR),  # returns 0 (fail)
    ("vc_dispmanx_update_submit_sync",        ARM_MVN_R0_0_BX_LR),  # returns -1
    ("vc_dispmanx_update_submit",             ARM_MVN_R0_0_BX_LR),  # returns -1
    ("vc_dispmanx_element_add",               ARM_MOV_R0_0_BX_LR),  # returns 0 (fail)
    ("vc_dispmanx_element_remove",            ARM_MVN_R0_0_BX_LR),  # returns -1
    ("vc_dispmanx_element_change_attributes", ARM_MVN_R0_0_BX_LR),  # returns -1
    ("vc_dispmanx_resource_create",           ARM_MOV_R0_0_BX_LR),  # returns 0 (fail)
    ("vc_dispmanx_resource_delete",           ARM_MVN_R0_0_BX_LR),  # returns -1
    ("vc_dispmanx_resource_write_data",       ARM_MVN_R0_0_BX_LR),  # returns -1
    ("graphics_get_display_size",             ARM_MVN_R0_0_BX_LR),  # returns -1
    ("vcos_init",                             ARM_MOV_R0_0_BX_LR),  # returns 0 (success)
]

# ELF constants
ELFCLASS32 = 1
ELFDATA2LSB = 1
ET_DYN = 3
EM_ARM = 40
PT_LOAD = 1
PT_DYNAMIC = 2
SHT_NULL = 0
SHT_PROGBITS = 1
SHT_STRTAB = 3
SHT_DYNSYM = 11
SHT_DYNAMIC = 6
SHT_HASH = 5
STB_GLOBAL = 1
STT_FUNC = 2
SHF_ALLOC = 2
SHF_EXECINSTR = 4
SHF_WRITE = 1
DT_NULL = 0
DT_HASH = 4
DT_STRTAB = 5
DT_SYMTAB = 6
DT_STRSZ = 10
DT_SYMENT = 11
DT_SONAME = 14

def align(val, alignment):
    return (val + alignment - 1) & ~(alignment - 1)

def build_elf():
    """Build a minimal ARM32 ELF shared library."""
    
    # Base address for the shared library
    BASE = 0x0  # Position-independent
    
    # Build string table (.dynstr)
    dynstr = b'\x00'  # null string at index 0
    soname = b'libbcm_host_stub.so\x00'
    soname_idx = len(dynstr)
    dynstr += soname
    
    sym_name_indices = []
    for name, _ in stubs:
        sym_name_indices.append(len(dynstr))
        dynstr += name.encode() + b'\x00'
    
    # Pad dynstr to 4-byte alignment
    while len(dynstr) % 4:
        dynstr += b'\x00'
    
    # Build code section (.text)
    code = b''
    sym_offsets = []
    for _, code_bytes in stubs:
        sym_offsets.append(len(code))
        code += code_bytes
    
    # Pad code to 4-byte alignment
    while len(code) % 4:
        code += b'\x00'
    
    # Build symbol table (.dynsym)
    # First entry is always null
    num_syms = 1 + len(stubs)
    dynsym = struct.pack('<IIIBBH', 0, 0, 0, 0, 0, 0)  # null symbol
    
    # Build hash table
    # Simple SYSV hash table
    nbucket = num_syms  # one bucket per symbol for simplicity
    nchain = num_syms
    
    def elf_hash(name):
        h = 0
        for c in name.encode():
            h = (h << 4) + c
            g = h & 0xF0000000
            if g:
                h ^= g >> 24
            h &= ~g
        return h
    
    # We'll fill in the hash table after we know symbol indices
    
    # Layout plan:
    # ELF header:       0x00 - 0x33 (52 bytes)
    # Program headers:  0x34 (2 entries * 32 bytes = 64 bytes) -> 0x74
    # .hash:            0x80 (align 16)
    # .dynsym:          after .hash
    # .dynstr:          after .dynsym
    # .text:            after .dynstr (aligned to 16)
    # .dynamic:         after .text (aligned to 8)
    # Section headers:  after .dynamic (aligned to 4)
    
    ehdr_size = 52
    phdr_size = 32
    num_phdrs = 2  # PT_LOAD + PT_DYNAMIC
    
    phdr_offset = ehdr_size
    
    # Start sections after program headers
    sections_start = align(phdr_offset + num_phdrs * phdr_size, 16)
    
    # .hash section
    hash_offset = sections_start
    
    # Build hash buckets and chains
    buckets = [0] * nbucket
    chains = [0] * nchain
    
    for i in range(1, num_syms):  # skip null symbol
        name = stubs[i-1][0]
        bucket_idx = elf_hash(name) % nbucket
        if buckets[bucket_idx] == 0:
            buckets[bucket_idx] = i
        else:
            # Chain from existing entry
            j = buckets[bucket_idx]
            while chains[j] != 0:
                j = chains[j]
            chains[j] = i
    
    hash_data = struct.pack('<II', nbucket, nchain)
    for b in buckets:
        hash_data += struct.pack('<I', b)
    for c in chains:
        hash_data += struct.pack('<I', c)
    
    hash_size = len(hash_data)
    
    # .dynsym section
    dynsym_offset = hash_offset + hash_size
    # Pad to 4-byte align
    dynsym_offset = align(dynsym_offset, 4)
    
    # .dynstr section  
    dynstr_offset = dynsym_offset + num_syms * 16  # each Elf32_Sym is 16 bytes
    
    # .text section
    text_offset = align(dynstr_offset + len(dynstr), 16)
    
    # .dynamic section
    dynamic_offset = align(text_offset + len(code), 8)
    
    # Build dynamic entries
    dynamic_entries = [
        (DT_SONAME, soname_idx),
        (DT_HASH, hash_offset),
        (DT_STRTAB, dynstr_offset),
        (DT_SYMTAB, dynsym_offset),
        (DT_STRSZ, len(dynstr)),
        (DT_SYMENT, 16),
        (DT_NULL, 0),
    ]
    
    dynamic_data = b''
    for tag, val in dynamic_entries:
        dynamic_data += struct.pack('<iI', tag, val)
    
    dynamic_size = len(dynamic_data)
    
    # Section headers (after dynamic)
    shdr_offset = align(dynamic_offset + dynamic_size, 4)
    
    # Now build symbol table entries with correct text offsets
    dynsym = struct.pack('<IIIBBH', 0, 0, 0, 0, 0, 0)  # null symbol
    
    text_section_idx = 4  # .text will be section index 4
    
    for i, (name, code_bytes) in enumerate(stubs):
        st_name = sym_name_indices[i]
        st_value = text_offset + sym_offsets[i]  # Virtual address = file offset for PIE
        st_size = len(code_bytes)
        st_info = (STB_GLOBAL << 4) | STT_FUNC
        st_other = 0  # STV_DEFAULT
        st_shndx = text_section_idx
        dynsym += struct.pack('<IIIBBH', st_name, st_value, st_size, st_info, st_other, st_shndx)
    
    # Total file size
    num_shdrs = 6  # null, .hash, .dynsym, .dynstr, .text, .dynamic
    total_size = shdr_offset + num_shdrs * 40  # each Elf32_Shdr is 40 bytes
    
    # Build the ELF file
    elf = bytearray(total_size)
    
    # ELF header
    elf[0:4] = b'\x7fELF'
    elf[4] = ELFCLASS32
    elf[5] = ELFDATA2LSB
    elf[6] = 1  # EV_CURRENT
    elf[7] = 0  # ELFOSABI_NONE
    struct.pack_into('<H', elf, 16, ET_DYN)
    struct.pack_into('<H', elf, 18, EM_ARM)
    struct.pack_into('<I', elf, 20, 1)  # e_version
    struct.pack_into('<I', elf, 24, 0)  # e_entry
    struct.pack_into('<I', elf, 28, phdr_offset)  # e_phoff
    struct.pack_into('<I', elf, 32, shdr_offset)  # e_shoff
    struct.pack_into('<I', elf, 36, 0x05000000)  # e_flags (ARM EABI5)
    struct.pack_into('<H', elf, 40, ehdr_size)  # e_ehsize
    struct.pack_into('<H', elf, 42, phdr_size)  # e_phentsize
    struct.pack_into('<H', elf, 44, num_phdrs)  # e_phnum
    struct.pack_into('<H', elf, 46, 40)  # e_shentsize
    struct.pack_into('<H', elf, 48, num_shdrs)  # e_shnum
    struct.pack_into('<H', elf, 50, 3)  # e_shstrndx (section 3 = .dynstr, reuse as shstrtab)
    
    # Program header 0: PT_LOAD (everything)
    off = phdr_offset
    struct.pack_into('<IIIIIIII', elf, off,
        PT_LOAD,        # p_type
        0,              # p_offset
        0,              # p_vaddr
        0,              # p_paddr
        total_size,     # p_filesz
        total_size,     # p_memsz
        5,              # p_flags (PF_R | PF_X)
        0x1000,         # p_align
    )
    
    # Program header 1: PT_DYNAMIC
    off = phdr_offset + phdr_size
    struct.pack_into('<IIIIIIII', elf, off,
        PT_DYNAMIC,     # p_type
        dynamic_offset, # p_offset
        dynamic_offset, # p_vaddr
        dynamic_offset, # p_paddr
        dynamic_size,   # p_filesz
        dynamic_size,   # p_memsz
        6,              # p_flags (PF_R | PF_W)
        4,              # p_align
    )
    
    # Write sections
    elf[hash_offset:hash_offset+hash_size] = hash_data
    elf[dynsym_offset:dynsym_offset+len(dynsym)] = dynsym
    elf[dynstr_offset:dynstr_offset+len(dynstr)] = dynstr
    elf[text_offset:text_offset+len(code)] = code
    elf[dynamic_offset:dynamic_offset+dynamic_size] = dynamic_data
    
    # Section headers
    # We need section name strings. Reuse .dynstr by adding section names at the end... 
    # Actually, simpler: use index 0 for all section names (empty string) since
    # the dynamic linker doesn't care about section names for .so resolution.
    
    def write_shdr(idx, sh_name, sh_type, sh_flags, sh_addr, sh_offset, sh_size, 
                   sh_link, sh_info, sh_addralign, sh_entsize):
        off = shdr_offset + idx * 40
        struct.pack_into('<IIIIIIIIII', elf, off,
            sh_name, sh_type, sh_flags, sh_addr, sh_offset, sh_size,
            sh_link, sh_info, sh_addralign, sh_entsize)
    
    # Section 0: null
    write_shdr(0, 0, SHT_NULL, 0, 0, 0, 0, 0, 0, 0, 0)
    # Section 1: .hash
    write_shdr(1, 0, SHT_HASH, SHF_ALLOC, hash_offset, hash_offset, hash_size, 2, 0, 4, 4)
    # Section 2: .dynsym
    write_shdr(2, 0, SHT_DYNSYM, SHF_ALLOC, dynsym_offset, dynsym_offset, len(dynsym), 3, 1, 4, 16)
    # Section 3: .dynstr
    write_shdr(3, 0, SHT_STRTAB, SHF_ALLOC, dynstr_offset, dynstr_offset, len(dynstr), 0, 0, 1, 0)
    # Section 4: .text
    write_shdr(4, 0, SHT_PROGBITS, SHF_ALLOC|SHF_EXECINSTR, text_offset, text_offset, len(code), 0, 0, 16, 0)
    # Section 5: .dynamic
    write_shdr(5, 0, SHT_DYNAMIC, SHF_ALLOC|SHF_WRITE, dynamic_offset, dynamic_offset, dynamic_size, 3, 0, 4, 8)
    
    return bytes(elf)

if __name__ == '__main__':
    elf = build_elf()
    outpath = os.path.join(os.path.dirname(__file__), 'libbcm_host_stub.so')
    with open(outpath, 'wb') as f:
        f.write(elf)
    os.chmod(outpath, 0o755)
    print(f"Generated {outpath} ({len(elf)} bytes)")
    print(f"Symbols: {', '.join(name for name, _ in stubs)}")
