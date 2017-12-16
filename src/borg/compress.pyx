"""
borg.compress
=============

Compression is applied to chunks after ID hashing (so the ID is a direct function of the
plain chunk, compression is irrelevant to it), and of course before encryption.

The "auto" mode (e.g. --compression auto,lzma,4) is implemented as a meta Compressor,
meaning that Auto acts like a Compressor, but defers actual work to others (namely
LZ4 as a heuristic whether compression is worth it, and the specified Compressor
for the actual compression).

Decompression is normally handled through Compressor.decompress which will detect
which compressor has been used to compress the data and dispatch to the correct
decompressor.
"""

import zlib

try:
    import lzma
except ImportError:
    lzma = None


from .helpers import Buffer, DecompressionError

API_VERSION = '1.1_04'

cdef extern from "lz4.h":
    int LZ4_compress_limitedOutput(const char* source, char* dest, int inputSize, int maxOutputSize) nogil
    int LZ4_decompress_safe(const char* source, char* dest, int inputSize, int maxOutputSize) nogil
    int LZ4_compressBound(int inputSize) nogil


cdef extern from "algorithms/zstd-libselect.h":
    size_t ZSTD_compress(void* dst, size_t dstCapacity, const void* src, size_t srcSize, int  compressionLevel) nogil
    size_t ZSTD_decompress(void* dst, size_t dstCapacity, const void* src, size_t compressedSize) nogil
    size_t ZSTD_compressBound(size_t srcSize) nogil
    unsigned long long ZSTD_CONTENTSIZE_UNKNOWN
    unsigned long long ZSTD_CONTENTSIZE_ERROR
    unsigned long long ZSTD_getFrameContentSize(const void *src, size_t srcSize) nogil
    unsigned ZSTD_isError(size_t code) nogil
    const char* ZSTD_getErrorName(size_t code) nogil


buffer = Buffer(bytearray, size=0)


cdef class CompressorBase:
    """
    base class for all (de)compression classes,
    also handles compression format auto detection and
    adding/stripping the ID header (which enable auto detection).
    """
    ID = b'\xFF\xFF'  # reserved and not used
                      # overwrite with a unique 2-bytes bytestring in child classes
    name = 'baseclass'

    @classmethod
    def detect(cls, data):
        return data.startswith(cls.ID)

    def __init__(self, **kwargs):
        pass

    def decide(self, data):
        """
        Return which compressor will perform the actual compression for *data*.

        This exists for a very specific case: If borg recreate is instructed to recompress
        using Auto compression it needs to determine the _actual_ target compression of a chunk
        in order to detect whether it should be recompressed.

        For all Compressors that are not Auto this always returns *self*.
        """
        return self

    def compress(self, data):
        """
        Compress *data* (bytes) and return bytes result. Prepend the ID bytes of this compressor,
        which is needed so that the correct decompressor can be used for decompression.
        """
        # add ID bytes
        return self.ID + data

    def decompress(self, data):
        """
        Decompress *data* (bytes) and return bytes result. The leading Compressor ID
        bytes need to be present.

        Only handles input generated by _this_ Compressor - for a general purpose
        decompression method see *Compressor.decompress*.
        """
        # strip ID bytes
        return data[2:]


class CNONE(CompressorBase):
    """
    none - no compression, just pass through data
    """
    ID = b'\x00\x00'
    name = 'none'

    def compress(self, data):
        return super().compress(data)

    def decompress(self, data):
        data = super().decompress(data)
        if not isinstance(data, bytes):
            data = bytes(data)
        return data


class LZ4(CompressorBase):
    """
    raw LZ4 compression / decompression (liblz4).

    Features:
        - lz4 is super fast
        - wrapper releases CPython's GIL to support multithreaded code
        - uses safe lz4 methods that never go beyond the end of the output buffer
    """
    ID = b'\x01\x00'
    name = 'lz4'

    def __init__(self, **kwargs):
        pass

    def compress(self, idata):
        if not isinstance(idata, bytes):
            idata = bytes(idata)  # code below does not work with memoryview
        cdef int isize = len(idata)
        cdef int osize
        cdef char *source = idata
        cdef char *dest
        osize = LZ4_compressBound(isize)
        buf = buffer.get(osize)
        dest = <char *> buf
        osize = LZ4_compress_limitedOutput(source, dest, isize, osize)
        if not osize:
            raise Exception('lz4 compress failed')
        return super().compress(dest[:osize])

    def decompress(self, idata):
        if not isinstance(idata, bytes):
            idata = bytes(idata)  # code below does not work with memoryview
        idata = super().decompress(idata)
        cdef int isize = len(idata)
        cdef int osize
        cdef int rsize
        cdef char *source = idata
        cdef char *dest
        # a bit more than 8MB is enough for the usual data sizes yielded by the chunker.
        # allocate more if isize * 3 is already bigger, to avoid having to resize often.
        osize = max(int(1.1 * 2**23), isize * 3)
        while True:
            try:
                buf = buffer.get(osize)
            except MemoryError:
                raise DecompressionError('MemoryError')
            dest = <char *> buf
            rsize = LZ4_decompress_safe(source, dest, isize, osize)
            if rsize >= 0:
                break
            if osize > 2 ** 27:  # 128MiB (should be enough, considering max. repo obj size and very good compression)
                # this is insane, get out of here
                raise DecompressionError('lz4 decompress failed')
            # likely the buffer was too small, get a bigger one:
            osize = int(1.5 * osize)
        return dest[:rsize]


class LZMA(CompressorBase):
    """
    lzma compression / decompression
    """
    ID = b'\x02\x00'
    name = 'lzma'

    def __init__(self, level=6, **kwargs):
        super().__init__(**kwargs)
        self.level = level
        if lzma is None:
            raise ValueError('No lzma support found.')

    def compress(self, data):
        # we do not need integrity checks in lzma, we do that already
        data = lzma.compress(data, preset=self.level, check=lzma.CHECK_NONE)
        return super().compress(data)

    def decompress(self, data):
        data = super().decompress(data)
        try:
            return lzma.decompress(data)
        except lzma.LZMAError as e:
            raise DecompressionError(str(e)) from None


class ZSTD(CompressorBase):
    """zstd compression / decompression (pypi: zstandard, gh: python-zstandard)"""
    # This is a NOT THREAD SAFE implementation.
    # Only ONE python context must to be created at a time.
    # It should work flawlessly as long as borg will call ONLY ONE compression job at time.
    ID = b'\x03\x00'
    name = 'zstd'

    def __init__(self, level=3, **kwargs):
        super().__init__(**kwargs)
        self.level = level

    def compress(self, idata):
        if not isinstance(idata, bytes):
            idata = bytes(idata)  # code below does not work with memoryview
        cdef int isize = len(idata)
        cdef size_t osize
        cdef char *source = idata
        cdef char *dest
        cdef int level = self.level
        osize = ZSTD_compressBound(isize)
        buf = buffer.get(osize)
        dest = <char *> buf
        with nogil:
            osize = ZSTD_compress(dest, osize, source, isize, level)
        if ZSTD_isError(osize):
            raise Exception('zstd compress failed: %s' % ZSTD_getErrorName(osize))
        return super().compress(dest[:osize])

    def decompress(self, idata):
        if not isinstance(idata, bytes):
            idata = bytes(idata)  # code below does not work with memoryview
        idata = super().decompress(idata)
        cdef int isize = len(idata)
        cdef unsigned long long osize
        cdef unsigned long long rsize
        cdef char *source = idata
        cdef char *dest
        osize = ZSTD_getFrameContentSize(source, isize)
        if osize == ZSTD_CONTENTSIZE_ERROR:
            raise DecompressionError('zstd get size failed: data was not compressed by zstd')
        if osize == ZSTD_CONTENTSIZE_UNKNOWN:
            raise DecompressionError('zstd get size failed: original size unknown')
        try:
            buf = buffer.get(osize)
        except MemoryError:
            raise DecompressionError('MemoryError')
        dest = <char *> buf
        with nogil:
            rsize = ZSTD_decompress(dest, osize, source, isize)
        if ZSTD_isError(rsize):
            raise DecompressionError('zstd decompress failed: %s' % ZSTD_getErrorName(rsize))
        if rsize != osize:
            raise DecompressionError('zstd decompress failed: size mismatch')
        return dest[:osize]


class ZLIB(CompressorBase):
    """
    zlib compression / decompression (python stdlib)
    """
    ID = b'\x08\x00'  # not used here, see detect()
                      # avoid all 0x.8.. IDs elsewhere!
    name = 'zlib'

    @classmethod
    def detect(cls, data):
        # matches misc. patterns 0x.8.. used by zlib
        cmf, flg = data[:2]
        is_deflate = cmf & 0x0f == 8
        check_ok = (cmf * 256 + flg) % 31 == 0
        return check_ok and is_deflate

    def __init__(self, level=6, **kwargs):
        super().__init__(**kwargs)
        self.level = level

    def compress(self, data):
        # note: for compatibility no super call, do not add ID bytes
        return zlib.compress(data, self.level)

    def decompress(self, data):
        # note: for compatibility no super call, do not strip ID bytes
        try:
            return zlib.decompress(data)
        except zlib.error as e:
            raise DecompressionError(str(e)) from None


class Auto(CompressorBase):
    """
    Meta-Compressor that decides which compression to use based on LZ4's ratio.

    As a meta-Compressor the actual compression is deferred to other Compressors,
    therefore this Compressor has no ID, no detect() and no decompress().
    """

    ID = None
    name = 'auto'

    def __init__(self, compressor):
        super().__init__()
        self.compressor = compressor
        self.lz4 = get_compressor('lz4')
        self.none = get_compressor('none')

    def _decide(self, data):
        """
        Decides what to do with *data*. Returns (compressor, lz4_data).

        *lz4_data* is the LZ4 result if *compressor* is LZ4 as well, otherwise it is None.
        """
        lz4_data = self.lz4.compress(data)
        ratio = len(lz4_data) / len(data)
        if ratio < 0.97:
            return self.compressor, lz4_data
        elif ratio < 1:
            return self.lz4, lz4_data
        else:
            return self.none, None

    def decide(self, data):
        return self._decide(data)[0]

    def compress(self, data):
        compressor, lz4_data = self._decide(data)
        if compressor is self.lz4:
            # we know that trying to compress with expensive compressor is likely pointless,
            # but lz4 managed to at least squeeze the data a bit.
            return lz4_data
        if compressor is self.none:
            # we know that trying to compress with expensive compressor is likely pointless
            # and also lz4 did not manage to squeeze the data (not even a bit).
            uncompressed_data = compressor.compress(data)
            return uncompressed_data
        # if we get here, the decider decided to try the expensive compressor.
        # we also know that lz4_data is smaller than uncompressed data.
        exp_compressed_data = compressor.compress(data)
        ratio = len(exp_compressed_data) / len(lz4_data)
        if ratio < 0.99:
            # the expensive compressor managed to squeeze the data significantly better than lz4.
            return exp_compressed_data
        else:
            # otherwise let's just store the lz4 data, which decompresses extremely fast.
            return lz4_data

    def decompress(self, data):
        raise NotImplementedError

    def detect(cls, data):
        raise NotImplementedError


# Maps valid compressor names to their class
COMPRESSOR_TABLE = {
    CNONE.name: CNONE,
    LZ4.name: LZ4,
    ZLIB.name: ZLIB,
    LZMA.name: LZMA,
    Auto.name: Auto,
    ZSTD.name: ZSTD,
}
# List of possible compression types. Does not include Auto, since it is a meta-Compressor.
COMPRESSOR_LIST = [LZ4, ZSTD, CNONE, ZLIB, LZMA, ]  # check fast stuff first

def get_compressor(name, **kwargs):
    cls = COMPRESSOR_TABLE[name]
    return cls(**kwargs)


class Compressor:
    """
    compresses using a compressor with given name and parameters
    decompresses everything we can handle (autodetect)
    """
    def __init__(self, name='null', **kwargs):
        self.params = kwargs
        self.compressor = get_compressor(name, **self.params)

    def compress(self, data):
        return self.compressor.compress(data)

    def decompress(self, data):
        compressor_cls = self.detect(data)
        return compressor_cls(**self.params).decompress(data)

    @staticmethod
    def detect(data):
        hdr = bytes(data[:2])  # detect() does not work with memoryview
        for cls in COMPRESSOR_LIST:
            if cls.detect(hdr):
                return cls
        else:
            raise ValueError('No decompressor for this data found: %r.', data[:2])


class CompressionSpec:
    def __init__(self, s):
        values = s.split(',')
        count = len(values)
        if count < 1:
            raise ValueError
        # --compression algo[,level]
        self.name = values[0]
        if self.name in ('none', 'lz4', ):
            return
        elif self.name in ('zlib', 'lzma', ):
            if count < 2:
                level = 6  # default compression level in py stdlib
            elif count == 2:
                level = int(values[1])
                if not 0 <= level <= 9:
                    raise ValueError
            else:
                raise ValueError
            self.level = level
        elif self.name in ('zstd', ):
            if count < 2:
                level = 3  # default compression level in zstd
            elif count == 2:
                level = int(values[1])
                if not 1 <= level <= 22:
                    raise ValueError
            else:
                raise ValueError
            self.level = level
        elif self.name == 'auto':
            if 2 <= count <= 3:
                compression = ','.join(values[1:])
            else:
                raise ValueError
            self.inner = CompressionSpec(compression)
        else:
            raise ValueError

    @property
    def compressor(self):
        if self.name in ('none', 'lz4', ):
            return get_compressor(self.name)
        elif self.name in ('zlib', 'lzma', 'zstd', ):
            return get_compressor(self.name, level=self.level)
        elif self.name == 'auto':
            return get_compressor(self.name, compressor=self.inner.compressor)
