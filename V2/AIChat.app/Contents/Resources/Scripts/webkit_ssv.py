#!/usr/bin/env python3
"""webkit_ssv.py - minimal decoder for WebKit SerializedScriptValue blobs.

This is the offline "escape hatch" (Route B) for importing the llama.cpp WebUI chat
history that AIChat.app (v1) stored in WebKit IndexedDB. The browser normally deserializes
these blobs natively (Route A: an in-app dump page); this module decodes the subset of the
format the WebUI actually uses so the same data can be recovered with the app closed.

Format (empirically confirmed against com.abracode.AIChat's IndexedDB, wire version 15):
  - 4-byte little-endian version header, then one tagged value.
  - Tags (standard WebKit SerializationTag enum):
        1 Array   2 Object   3 Undefined 4 Null   5 Int32
        6 Zero    7 One      8 False     9 True   10 Double  11 Date
        16 String 17 EmptyString
  - Strings: uint32 lengthAndFlags; bit 0x80000000 set => 8-bit Latin1 (`length` bytes),
    else UTF-16LE (`length*2` bytes). 0xFFFFFFFF = terminator, 0xFFFFFFFE = string-pool
    back-reference followed by a VARIABLE-WIDTH index into previously-read strings: 1 byte
    while the pool holds <=0xFF entries, 2 bytes while <=0xFFFF, else 4 (WebKit writes the
    constant-pool index at the narrowest width that fits the current pool size).
  - Object: (propertyNameString, value)* until a 0xFFFFFFFF terminator.
  - Array: uint32 length, then (indexUint32, value)* until index==0xFFFFFFFF, then
    (propertyNameString, value)* until terminator.
  - ObjectReference (tag 19): a variable-width index (same 1/2/4-byte scheme, by object-pool
    size) into the objects/arrays deserialized so far - WebKit dedups repeated references
    (e.g. a shared empty array) instead of re-serializing them.

Only this subset is handled; an unmapped tag raises SSVError so the caller can skip and
report that one record rather than aborting the whole import. No third-party deps.
"""
import struct

TERMINATOR = 0xFFFFFFFF
STRING_POOL = 0xFFFFFFFE

# SerializationTag values
T_ARRAY = 1
T_OBJECT = 2
T_UNDEFINED = 3
T_NULL = 4
T_INT = 5
T_ZERO = 6
T_ONE = 7
T_FALSE = 8
T_TRUE = 9
T_DOUBLE = 10
T_DATE = 11
T_STRING = 16
T_EMPTY_STRING = 17
T_OBJECT_REFERENCE = 19

_TERM = object()  # sentinel returned when a property-name read hits the terminator


class SSVError(Exception):
    pass


class _Reader:
    def __init__(self, data):
        self.d = data
        self.n = len(data)
        self.i = 0
        self.pool = []     # constant pool of previously-read strings (back-ref targets)
        self.objects = []  # object pool of deserialized objects/arrays (ObjectReference targets)

    def _need(self, k):
        if self.i + k > self.n:
            raise SSVError("unexpected end of blob at %d (need %d)" % (self.i, k))

    def u8(self):
        self._need(1)
        v = self.d[self.i]
        self.i += 1
        return v

    def u16(self):
        self._need(2)
        v = struct.unpack_from("<H", self.d, self.i)[0]
        self.i += 2
        return v

    def u32(self):
        self._need(4)
        v = struct.unpack_from("<I", self.d, self.i)[0]
        self.i += 4
        return v

    def _index(self, count):
        # WebKit writes a pool index at the narrowest width fitting the current pool size:
        # 1 byte while <=0xFF entries, 2 while <=0xFFFF, else 4.
        if count <= 0xFF:
            return self.u8()
        if count <= 0xFFFF:
            return self.u16()
        return self.u32()

    def i32(self):
        self._need(4)
        v = struct.unpack_from("<i", self.d, self.i)[0]
        self.i += 4
        return v

    def f64(self):
        self._need(8)
        v = struct.unpack_from("<d", self.d, self.i)[0]
        self.i += 8
        return v

    def read_string(self):
        """Read a CachedString. Returns _TERM at a terminator, else the str."""
        length = self.u32()
        if length == TERMINATOR:
            return _TERM
        if length == STRING_POOL:
            idx = self._index(len(self.pool))
            if idx >= len(self.pool):
                raise SSVError("string-pool index %d out of range" % idx)
            return self.pool[idx]
        is8bit = (length & 0x80000000) != 0
        n = length & 0x7FFFFFFF
        if is8bit:
            self._need(n)
            s = self.d[self.i:self.i + n].decode("latin-1")
            self.i += n
        else:
            self._need(n * 2)
            s = self.d[self.i:self.i + n * 2].decode("utf-16-le")
            self.i += n * 2
        self.pool.append(s)
        return s

    def read_value(self):
        tag = self.u8()
        if tag == T_OBJECT:
            return self.read_object()
        if tag == T_ARRAY:
            return self.read_array()
        if tag == T_STRING:
            s = self.read_string()
            if s is _TERM:
                raise SSVError("terminator where a string value was expected")
            return s
        if tag == T_EMPTY_STRING:
            return ""
        if tag == T_OBJECT_REFERENCE:
            idx = self._index(len(self.objects))
            if idx >= len(self.objects):
                raise SSVError("object-reference index %d out of range" % idx)
            return self.objects[idx]
        if tag == T_NULL or tag == T_UNDEFINED:
            return None
        if tag == T_INT:
            return self.i32()
        if tag == T_ZERO:
            return 0
        if tag == T_ONE:
            return 1
        if tag == T_FALSE:
            return False
        if tag == T_TRUE:
            return True
        if tag == T_DOUBLE or tag == T_DATE:
            return self.f64()
        raise SSVError("unhandled tag %d at offset %d" % (tag, self.i - 1))

    def read_object(self):
        obj = {}
        self.objects.append(obj)  # register before populating so back-references resolve
        while True:
            name = self.read_string()
            if name is _TERM:
                break
            obj[name] = self.read_value()
        return obj

    def read_array(self):
        length = self.u32()
        arr = [None] * (length if length < 1 << 20 else 0)  # guard absurd lengths
        self.objects.append(arr)  # register before populating
        # indexed properties
        while True:
            idx = self.u32()
            if idx == TERMINATOR:
                break
            val = self.read_value()
            if idx < len(arr):
                arr[idx] = val
            else:
                # sparse / beyond declared length - extend
                while len(arr) < idx:
                    arr.append(None)
                arr.append(val)
        # named properties on the array (rare) - decode and discard to stay aligned
        while True:
            name = self.read_string()
            if name is _TERM:
                break
            self.read_value()
        return arr


def deserialize(blob):
    """Decode a WebKit SerializedScriptValue blob to a Python value."""
    if not blob:
        return None
    r = _Reader(bytes(blob))
    r.u32()  # version header
    return r.read_value()


if __name__ == "__main__":
    # Self-test / coverage probe: point at an IndexedDB.sqlite3 and report decode coverage.
    import sqlite3
    import sys
    if len(sys.argv) < 2:
        sys.stderr.write("usage: webkit_ssv.py <IndexedDB.sqlite3>\n")
        sys.exit(2)
    conn = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
    stores = dict(conn.execute("SELECT id, name FROM ObjectStoreInfo"))
    for sid, sname in stores.items():
        ok = fail = 0
        first_err = ""
        sample = None
        for (val,) in conn.execute("SELECT value FROM Records WHERE objectStoreID=?", (sid,)):
            try:
                obj = deserialize(val)
                if sample is None:
                    sample = obj
                ok += 1
            except Exception as e:
                fail += 1
                if not first_err:
                    first_err = str(e)
        print("store %s (%s): %d decoded, %d failed%s"
              % (sid, sname, ok, fail, (" - first error: " + first_err) if first_err else ""))
        if sample is not None:
            keys = sorted(sample.keys()) if isinstance(sample, dict) else type(sample).__name__
            print("   sample keys:", keys)
