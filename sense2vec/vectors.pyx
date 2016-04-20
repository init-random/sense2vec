# cython: profile=True
# cython: cdivision=True
# cython: infer_types=True
cimport cython.parallel
from libc.stdint cimport int32_t
from libc.stdint cimport uint64_t
from libc.string cimport memcpy, memset
from libcpp.pair cimport pair
from libcpp.queue cimport priority_queue
from libcpp.vector cimport vector
from spacy.cfile cimport CFile
from preshed.maps cimport PreshMap
from spacy.strings cimport StringStore, hash_string
from murmurhash.mrmr cimport hash64

cimport posix.stdlib
from cymem.cymem cimport Pool
cimport numpy as np
from libc.math cimport sqrt
import numpy
from os import path
try:
    import ujson as json
except ImportError:
    import json


ctypedef pair[float, int] Entry
ctypedef priority_queue[Entry] Queue


cdef struct _CachedResult:
    int* indices
    float* scores
    int n


cdef class VectorMap:
    '''Provide key-based access into the VectorStore. Keys are unicode strings.
    Also manage freqs.'''
    cdef readonly Pool mem
    cdef VectorStore data
    cdef readonly StringStore strings
    cdef PreshMap freqs
    
    def __init__(self, nr_dim):
        self.data = VectorStore(nr_dim)
        self.strings = StringStore()
        self.freqs = PreshMap()
    
    def __contains__(self, unicode string):
        cdef uint64_t hashed = hash_string(string)
        return bool(self.freqs[hashed])

    def __getitem__(self, unicode string):
        cdef uint64_t hashed = hash_string(string)
        freq = self.freqs[hashed]
        if not freq:
            raise KeyError(string)
        else:
            i = self.strings[string]
            return freq, self.data[i]

    def __iter__(self):
        cdef uint64_t hashed
        for i, string in enumerate(self.strings):
            hashed = hash_string(string)
            freq = self.freqs[hashed]
            yield (string, freq, self.data[i])

    def most_similar(self, float[:] vector, int n):
        indices, scores = self.data.most_similar(vector, n)
        return [self.strings[idx] for idx in indices], scores

    def add(self, unicode string, int freq, float[:] vector):
        idx = self.strings[string]
        cdef uint64_t hashed = hash_string(string)
        self.freqs[hashed] = freq
        assert self.data.vectors.size() == idx
        self.data.add(vector)

    def borrow(self, unicode string, int freq, float[:] vector):
        idx = self.strings[string]
        cdef uint64_t hashed = hash_string(string)
        self.freqs[hashed] = freq
        assert self.data.vectors.size() == idx
        self.data.borrow(vector)

    def save(self, data_dir):
        with open(path.join(data_dir, 'strings.json'), 'w') as file_:
            self.strings.dump(file_)
        self.data.save(path.join(data_dir, 'vectors.bin'))
        freqs = []
        cdef uint64_t hashed
        for string in self.strings:
            hashed = hash_string(string)
            freq = self.freqs[hashed]
            if not freq:
                continue
            freqs.append([string, freq])
        with open(path.join(data_dir, 'freqs.json'), 'w') as file_:
            json.dump(freqs, file_)

    def load(self, data_dir):
        self.data.load(path.join(data_dir, 'vectors.bin'))
        with open(path.join(data_dir, 'strings.json')) as file_:
            self.strings.load(file_)
        with open(path.join(data_dir, 'freqs.json')) as file_:
            freqs = json.load(file_)
        cdef uint64_t hashed
        for string, freq in freqs:
            hashed = hash_string(string)
            self.freqs[hashed] = freq


cdef class VectorStore:
    '''Maintain an array of float* pointers for word vectors, which the
    table may or may not own. Keys and frequencies sold separately --- 
    we're just a dumb vector of data, that knows how to run linear-scan
    similarity queries.'''
    cdef readonly Pool mem
    cdef readonly PreshMap cache
    cdef vector[float*] vectors
    cdef vector[float] norms
    cdef readonly int nr_dim
    
    def __init__(self, int nr_dim):
        self.mem = Pool()
        self.nr_dim = nr_dim 

        cdef aligned_allocator mem
        cdef float* zeros = mem.allocate(self.nr_dim)
        memset(zeros, 0, self.nr_dim * sizeof(float))

        self.vectors.push_back(zeros)
        self.norms.push_back(0)
        self.cache = PreshMap(100000)

    def __getitem__(self, int i):
        cdef float* ptr = self.vectors.at(i)
        cv = <float[:self.nr_dim]>ptr
        return numpy.asarray(cv)

    def add(self, float[:] vec):
        assert len(vec) == self.nr_dim

        cdef aligned_allocator mem
        cdef float* ptr = mem.allocate(self.nr_dim)

        memcpy(ptr, &vec[0], sizeof(ptr[0]) * self.nr_dim)
        self.norms.push_back(get_l2_norm(&ptr[0], self.nr_dim))
        self.vectors.push_back(ptr)
    
    def borrow(self, float[:] vec):
        self.norms.push_back(get_l2_norm(&vec[0], self.nr_dim))
        # Danger! User must ensure this is memory contiguous!
        self.vectors.push_back(&vec[0])

    def most_similar(self, float[:] query, int n):
        cdef int[:] indices = np.ndarray(shape=(n,), dtype='int32')
        cdef float[:] scores = np.ndarray(shape=(n,), dtype='float32')
        cdef uint64_t cache_key = hash64(&query[0], sizeof(query[0]) * n, 0)
        cached_result = <_CachedResult*>self.cache.get(cache_key)
        if cached_result is not NULL and cached_result.n == n:
            memcpy(&indices[0], cached_result.indices, sizeof(indices[0]) * n)
            memcpy(&scores[0], cached_result.scores, sizeof(scores[0]) * n)
        else:
            # This shouldn't happen. But handle it if it does
            if cached_result is not NULL:
                if cached_result.indices is not NULL:
                    self.mem.free(cached_result.indices)
                if cached_result.scores is not NULL:
                    self.mem.free(cached_result.scores)
                self.mem.free(cached_result)
            self.linear_similarity(indices, scores, n, query, self.nr_dim)
            cached_result = <_CachedResult*>self.mem.alloc(sizeof(_CachedResult), 1)
            cached_result.n = n
            cached_result.indices = <int*>self.mem.alloc(
                sizeof(cached_result.indices[0]), n)
            cached_result.scores = <float*>self.mem.alloc(
                sizeof(cached_result.scores[0]), n)
            self.cache.set(cache_key, cached_result)
            memcpy(cached_result.indices, &indices[0], sizeof(indices[0]) * n)
            memcpy(cached_result.scores, &scores[0], sizeof(scores[0]) * n)
        return indices, scores

    def save(self, loc):
        cdef CFile cfile = CFile(loc, 'wb')
        cdef float* vec
        cdef int32_t nr_vector = self.vectors.size()
        cfile.write_from(&nr_vector, 1, sizeof(nr_vector))
        cfile.write_from(&self.nr_dim, 1, sizeof(self.nr_dim))
        for vec in self.vectors:
            cfile.write_from(vec, self.nr_dim, sizeof(vec[0]))
        cfile.close()

    def load(self, loc):
        cdef CFile cfile = CFile(loc, 'rb')
        cdef int32_t nr_vector
        cfile.read_into(&nr_vector, 1, sizeof(nr_vector))
        cfile.read_into(&self.nr_dim, 1, sizeof(self.nr_dim))
        cdef vector[float] tmp
        tmp.resize(self.nr_dim)
        cdef float[:] cv
        for i in range(nr_vector):
            cfile.read_into(&tmp[0], self.nr_dim, sizeof(tmp[0]))
            ptr = &tmp[0]
            cv = <float[:128]>ptr
            if i >= 1:
                self.add(cv)
        cfile.close()


    def linear_similarity(self, int[:] indices, float[:] scores,
            int nr_out, float[:] query, int nr_dim):

        query_norm = get_l2_norm(&query[0], nr_dim)

        cdef vector[float] scores_tmp
        scores_tmp.resize(self.vectors.size())

        cdef int i
        for i in cython.parallel.prange(self.vectors.size(), nogil=True):
            scores_tmp[i] = cosine_similarity(&query[0], (&self.vectors[0])[i], query_norm, (&self.norms[0])[i], nr_dim)

        # Initialize the partially sorted heap
        cdef float score
        cdef priority_queue[pair[float, int]] queue
        cdef float cutoff = 0
        for i in range(scores_tmp.size()):
            score = scores_tmp[i]
            if score > cutoff:
                queue.push(pair[float, int](-score, i))
                cutoff = -queue.top().first
                if queue.size() > nr_out:
                    queue.pop()

        # Fill the outputs
        i = 0
        while i < nr_out and not queue.empty():
            entry = queue.top()
            scores[nr_out-(i+1)] = -entry.first
            indices[nr_out-(i+1)] = entry.second
            queue.pop()
            i += 1


cdef extern from "<simdpp/simd.h>":
    int SIMDPP_FAST_FLOAT32_SIZE


cdef extern from "<simdpp/simd.h>" namespace "simdpp":
    cppclass float32[SIMDPP_FAST_FLOAT32_SIZE]:
        float32() nogil

    cppclass aligned_allocator "simdpp::aligned_allocator<float, 32>":
        float* allocate(int)

    float32 mul(float32, float32) nogil
    float32 add(float32, float32) nogil
    float32 load(void*) nogil
    float reduce_add(float32) nogil
    float32 make_float(double, double, double, double) nogil


cdef float get_l2_norm(const float* vec, int n) nogil:

    cdef float32 x
    cdef float32 z = make_float(0, 0, 0, 0)

    cdef int i = 0
    while i < n:
        x = load(&vec[i])
        z = add(mul(x, x), z)
        i += SIMDPP_FAST_FLOAT32_SIZE

    return sqrt(reduce_add(z))


cdef float cosine_similarity(const float* v1, const float* v2,
                             float norm1, float norm2, int n) nogil:

    cdef float32 x
    cdef float32 z = make_float(0, 0, 0, 0)

    cdef int i = 0
    while i < n:
        x = load(&v1[i])
        y = load(&v2[i])
        z = add(mul(x, y), z)
        i += SIMDPP_FAST_FLOAT32_SIZE

    return reduce_add(z) / (norm1 * norm2)
