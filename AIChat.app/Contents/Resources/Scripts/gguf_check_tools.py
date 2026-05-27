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

        def skip(t):
            if t == 8:    # string
                f.seek(struct.unpack('<Q', f.read(8))[0], 1)
            elif t == 9:  # array
                et = struct.unpack('<I', f.read(4))[0]
                for _ in range(struct.unpack('<Q', f.read(8))[0]):
                    skip(et)
            elif t in (0, 1, 7):  f.seek(1, 1)   # uint8 / int8 / bool
            elif t in (2, 3):     f.seek(2, 1)   # uint16 / int16
            elif t in (4, 5, 6):  f.seek(4, 1)   # uint32 / int32 / float32
            else:                 f.seek(8, 1)   # uint64 / int64 / float64

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
