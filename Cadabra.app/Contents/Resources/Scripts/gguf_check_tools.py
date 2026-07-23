#!/usr/bin/env python3
"""Read GGUF metadata header and check if the model's chat template supports tool calling."""

import struct
import sys


def gguf_chat_template(path):
    with open(path, 'rb') as f:
        if f.read(4) != b'GGUF':
            return None
        f.read(4)  # version
        f.read(8)  # tensor count
        kv_count = struct.unpack('<Q', f.read(8))[0]

        def read_str():
            n = struct.unpack('<Q', f.read(8))[0]
            return f.read(n).decode('utf-8', errors='replace')

        # Byte width of every fixed-size GGUF metadata type. Types absent here (8 string,
        # 9 array) are variable-length and must be walked.
        WIDTH = {0: 1, 1: 1, 7: 1,          # uint8 / int8 / bool
                 2: 2, 3: 2,                # uint16 / int16
                 4: 4, 5: 4, 6: 4,          # uint32 / int32 / float32
                 10: 8, 11: 8, 12: 8}       # uint64 / int64 / float64

        def skip(t):
            if t == 8:    # string
                f.seek(struct.unpack('<Q', f.read(8))[0], 1)
            elif t == 9:  # array
                et = struct.unpack('<I', f.read(4))[0]
                n = struct.unpack('<Q', f.read(8))[0]
                w = WIDTH.get(et)
                if w is not None:
                    # Fixed-width elements: jump the whole array in ONE seek. This is the
                    # difference between opening the picker and hanging it - tokenizer.
                    # ggml.scores / .token_type carry one entry per vocab token (250k+ is
                    # normal), and stepping them individually meant a quarter-million
                    # Python-level seeks, each one discarding the reader's buffer.
                    f.seek(n * w, 1)
                else:
                    for _ in range(n):
                        skip(et)
            else:
                f.seek(WIDTH.get(t, 8), 1)

        for _ in range(kv_count):
            key = read_str()
            vtype = struct.unpack('<I', f.read(4))[0]
            if key == 'tokenizer.chat_template':
                return read_str() if vtype == 8 else None
            skip(vtype)
    return None


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('false')
        sys.exit(0)
    try:
        tmpl = gguf_chat_template(sys.argv[1])
        print('true' if tmpl and 'tool_call' in tmpl else 'false')
    except Exception as e:
        print(f'error: {e}', file=sys.stderr)
        print('false')
