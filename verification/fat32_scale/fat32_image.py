"""Sparse FAT32 TF-card image builder for RTL simulation (test infrastructure only).

Builds an MBR-partitioned (or bare VBR) FAT32 volume that satisfies the RTL scanner's
checks (512-byte sectors, >=65525 clusters, two FATs, root cluster chain), with
optional fragmented cluster chains and padding directory entries that push files
into later root-directory clusters. Only non-zero sectors are stored; the SD model
returns zeros for anything else. Never touches a real card.
"""
from pathlib import Path
import random
import struct

SECTOR = 512
EOC = 0x0FFFFFFF


def short_name(name):
    base, _, ext = name.upper().partition('.')
    return (base.ljust(8) + ext.ljust(3)).encode('ascii')


def dir_entry(name11, attr, cluster, size):
    return struct.pack('<11sBBBHHHHHHHI', name11, attr, 0, 0, 0, 0, 0,
                       cluster >> 16, 0, 0, cluster & 0xFFFF, size)


class Fat32Image:
    def __init__(self, files, spc=8, clusters=66000, partition_lba=2048, partitioned=True,
                 fragment=False, dir_padding=0, seed=1, reserved=32, gap_max=4):
        self.spc, self.cluster_bytes = spc, spc * SECTOR
        rng = random.Random(seed)
        self.fat_size = -(-(clusters + 2) * 4 // SECTOR)
        self.total = reserved + 2 * self.fat_size + clusters * spc
        self.volume_lba = partition_lba if partitioned else 0
        self.fat_lba = self.volume_lba + reserved
        self.data_lba = self.fat_lba + 2 * self.fat_size
        self.max_cluster = clusters + 1
        self.sectors = {}
        self.fat = {0: 0x0FFFFFF8, 1: EOC}
        # Root directory: special entries the scanner must skip, padding, then files.
        entries = [dir_entry(b'TESTCARD   ', 0x08, 0, 0),
                   bytes([0xE5]) + dir_entry(b'XPIC1   BMP', 0x20, 5, 100)[1:],
                   b'A' + bytes(10) + b'\x0f' + bytes(20),            # LFN fragment
                   dir_entry(b'DOCS       ', 0x10, 0, 0)]
        entries += [dir_entry(f'PAD{i:05d}TXT'.encode(), 0x20, 0, 0) for i in range(dir_padding)]
        names = [short_name(n) for n, _ in files]
        root_bytes = (len(entries) + len(files)) * 32
        root_clusters = max(1, -(-root_bytes // self.cluster_bytes))
        # Allocation: root first (starting at cluster 2), then files in chunks.
        needs = [('root', root_clusters)] + [(i, max(1, -(-len(d) // self.cluster_bytes)))
                                             for i, (_, d) in enumerate(files)]
        chunks = []
        for owner, count in needs:
            while count:
                take = min(count, rng.randint(1, 3)) if fragment else count
                chunks.append((owner, take))
                count -= take
        if fragment:
            # Root's first chunk stays at cluster 2; the rest interleave between owners.
            # Chains are built in allocation order, so each file's data follows its chain.
            rest = chunks[1:]
            rng.shuffle(rest)
            chunks = [chunks[0]] + rest
        chains = {}
        cursor = 2
        for owner, take in chunks:
            if fragment and owner != 'root' and rng.random() < 0.5:
                cursor += rng.randint(1, gap_max)  # free gap
            chains.setdefault(owner, []).extend(range(cursor, cursor + take))
            cursor += take
        if cursor > self.max_cluster:
            raise ValueError('volume too small')
        if fragment:
            # Make some chains run backwards in cluster number.
            for owner in list(chains):
                if owner != 'root' and len(chains[owner]) > 2 and rng.random() < 0.5:
                    chains[owner] = chains[owner][::-1]
        if chains['root'][0] != 2:
            raise AssertionError('root must start at cluster 2')
        self.chains = chains
        for chain in chains.values():
            for a, b in zip(chain, chain[1:]):
                self.fat[a] = b
            self.fat[chain[-1]] = EOC
        directory = b''.join(entries) + b''.join(
            dir_entry(names[i], 0x20 | (0x01 if i % 2 else 0), chains[i][0], len(d))
            for i, (_, d) in enumerate(files))
        self._write_chain(chains['root'], directory)
        for i, (_, d) in enumerate(files):
            self._write_chain(chains[i], d)
        self._write_fat()
        self._write_boot(reserved, partitioned)

    def cluster_lba(self, cluster):
        return self.data_lba + (cluster - 2) * self.spc

    def _put(self, lba, data):
        data = bytes(data).ljust(SECTOR, b'\0')
        if any(data):
            self.sectors[lba] = data

    def _write_chain(self, chain, data):
        for n, cluster in enumerate(chain):
            part = data[n * self.cluster_bytes:(n + 1) * self.cluster_bytes]
            for s in range(self.spc):
                self._put(self.cluster_lba(cluster) + s, part[s * SECTOR:(s + 1) * SECTOR])

    def _write_fat(self):
        by_sector = {}
        for cluster, value in self.fat.items():
            by_sector.setdefault(cluster // 128, bytearray(SECTOR))
            struct.pack_into('<I', by_sector[cluster // 128], (cluster % 128) * 4, value)
        for copy in range(2):
            for index, data in by_sector.items():
                self._put(self.fat_lba + copy * self.fat_size + index, data)

    def _write_boot(self, reserved, partitioned):
        vbr = bytearray(SECTOR)
        vbr[0:3] = b'\xEB\x58\x90'
        vbr[3:11] = b'MSWIN4.1'
        struct.pack_into('<HBHBHHBHHHII', vbr, 11, SECTOR, self.spc, reserved, 2, 0, 0, 0xF8, 0,
                         63, 255, self.volume_lba, self.total)
        struct.pack_into('<IHHIHH', vbr, 36, self.fat_size, 0, 0, 2, 1, 6)
        vbr[82:90] = b'FAT32   '
        vbr[510:512] = b'\x55\xAA'
        self._put(self.volume_lba, vbr)
        if partitioned:
            mbr = bytearray(SECTOR)
            struct.pack_into('<B3sB3sII', mbr, 446, 0, b'\0\0\0', 0x0C, b'\0\0\0',
                             self.volume_lba, self.total)
            mbr[510:512] = b'\x55\xAA'
            self._put(0, mbr)

    def corrupt_fat(self, cluster, value):
        """Overwrite one FAT entry in both copies (for chain-error tests)."""
        self.fat[cluster] = value
        self._write_fat()

    def write_hex(self, directory):
        directory = Path(directory)
        lbas = sorted(self.sectors)
        (directory / 'sd_lba.hex').write_text(''.join(f'{l:08x}\n' for l in lbas))
        with open(directory / 'sd_data.hex', 'w') as f:
            for l in lbas:
                f.write('\n'.join(f'{b:02x}' for b in self.sectors[l]) + '\n')
        return len(lbas)
