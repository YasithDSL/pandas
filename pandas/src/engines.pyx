from numpy cimport ndarray


cdef inline is_definitely_invalid_key(object val):
    return PySlice_Check(val) or cnp.PyArray_Check(val)

from numpy cimport float64_t, int32_t, int64_t, uint8_t
cimport cython

cimport numpy as cnp

cnp.import_array()
cnp.import_ufunc()

cimport util

import numpy as np

import _tseries

include "hashtable.pyx"

cdef extern from "datetime.h":
    bint PyDateTime_Check(object o)
    void PyDateTime_IMPORT()

PyDateTime_IMPORT

cdef extern from "Python.h":
    int PySlice_Check(object)

def get_value_at(ndarray arr, object loc):
    return util.get_value_at(arr, loc)

def set_value_at(ndarray arr, object loc, object val):
    return util.set_value_at(arr, loc, val)

cdef class IndexEngine:

    cdef readonly:
        object index_weakref
        HashTable mapping

    cdef:
        bint unique, monotonic
        bint initialized, monotonic_check, unique_check

    def __init__(self, index_weakref):
        self.index_weakref = index_weakref
        self.initialized = 0
        self.monotonic_check = 0

        self.unique = 0
        self.monotonic = 0

    def __contains__(self, object val):
        self._ensure_mapping_populated()
        return val in self.mapping

    cpdef get_value(self, ndarray arr, object key):
        '''
        arr : 1-dimensional ndarray
        '''
        cdef:
            Py_ssize_t loc
            void* data_ptr

        loc = self.get_loc(key)
        return util.get_value_at(arr, loc)

    cpdef set_value(self, ndarray arr, object key, object value):
        '''
        arr : 1-dimensional ndarray
        '''
        cdef:
            Py_ssize_t loc
            void* data_ptr

        loc = self.get_loc(key)
        util.set_value_at(arr, loc, value)

    property is_unique:

        def __get__(self):
            if not self.unique_check:
                self._do_unique_check()

            return self.unique == 1

    property is_monotonic:

        def __get__(self):
            if not self.monotonic_check:
                self._do_monotonic_check()

            return self.monotonic == 1

    cdef inline _do_monotonic_check(self):
        try:
            values = self._get_index_values()
            self.monotonic, unique = self._call_monotonic(values)

            if unique is not None:
                self.unique = unique
                self.unique_check = 1

        except TypeError:
            self.monotonic = 0
        self.monotonic_check = 1

    cdef _get_index_values(self):
        return self.index_weakref().values

    cdef inline _do_unique_check(self):
        self._ensure_mapping_populated()

    def _call_monotonic(self, values):
        raise NotImplementedError

    cdef _make_hash_table(self, n):
        raise NotImplementedError

    cpdef get_loc(self, object val):
        if is_definitely_invalid_key(val):
            raise TypeError

        self._ensure_mapping_populated()
        if not self.unique:
            raise Exception('Index values are not unique')

        return self.mapping.get_item(val)

    cdef inline _ensure_mapping_populated(self):
        if not self.initialized:
            self.initialize()

    cdef initialize(self):
        values = self._get_index_values()

        self.mapping = self._make_hash_table(len(values))
        self.mapping.map_locations(values)

        if len(self.mapping) == len(values):
            self.unique = 1
            self.unique_check = 1

        self.initialized = 1

    def clear_mapping(self):
        self.mapping = None
        self.initialized = 0

    def get_indexer(self, values):
        self._ensure_mapping_populated()
        return self.mapping.lookup(values)



# @cache_readonly
# def _monotonicity_check(self):
#     try:
#         f = self._algos['is_monotonic']
#         # wrong buffer type raises ValueError
#         return f(self.values)
#     except TypeError:
#         return False, None



cdef class Int64Engine(IndexEngine):

    # cdef Int64HashTable mapping

    cdef _make_hash_table(self, n):
        return Int64HashTable(n)

    def _call_monotonic(self, values):
        return _tseries.is_monotonic_int64(values)

    def get_pad_indexer(self, other):
        return _tseries.pad_int64(self._get_index_values(), other)

    def get_backfill_indexer(self, other):
        return _tseries.backfill_int64(self._get_index_values(), other)

cdef class Float64Engine(IndexEngine):

    # cdef Float64HashTable mapping

    cdef _make_hash_table(self, n):
        return Float64HashTable(n)

    def _call_monotonic(self, values):
        return _tseries.is_monotonic_float64(values)

    def get_pad_indexer(self, other):
        return _tseries.pad_float64(self._get_index_values(), other)

    def get_backfill_indexer(self, other):
        return _tseries.backfill_float64(self._get_index_values(), other)


cdef class ObjectEngine(IndexEngine):

    # cdef PyObjectHashTable mapping

    cdef _make_hash_table(self, n):
        return PyObjectHashTable(n)

    def _call_monotonic(self, values):
        return _tseries.is_monotonic_object(values)

    def get_pad_indexer(self, other):
        return _tseries.pad_object(self._get_index_values(), other)

    def get_backfill_indexer(self, other):
        return _tseries.backfill_object(self._get_index_values(), other)


cdef class DatetimeEngine(IndexEngine):

    # cdef Int64HashTable mapping

    def __contains__(self, object val):
        self._ensure_mapping_populated()

        if util.is_datetime64_object(val):
            return val.view('i8') in self.mapping

        if PyDateTime_Check(val):
            key = np.datetime64(val)
            return key.view('i8') in self.mapping

        return val in self.mapping

    cdef _make_hash_table(self, n):
        return Int64HashTable(n)

    cdef _get_index_values(self):
        return self.index_weakref().values.view('i8')

    cpdef get_loc(self, object val):
        if is_definitely_invalid_key(val):
            raise TypeError

        self._ensure_mapping_populated()
        if not self.unique:
            raise Exception('Index values are not unique')

        if util.is_datetime64_object(val):
            val = val.view('i8')

        if PyDateTime_Check(val):
            val = np.datetime64(val)
            val = val.view('i8')

        return self.mapping.get_item(val)


# ctypedef fused idxvalue_t:
#     object
#     int
#     float64_t
#     int32_t
#     int64_t

# @cython.boundscheck(False)
# @cython.wraparound(False)
# def is_monotonic(ndarray[idxvalue_t] arr):
#     '''
#     Returns
#     -------
#     is_monotonic, is_unique
#     '''
#     cdef:
#         Py_ssize_t i, n
#         idxvalue_t prev, cur
#         bint is_unique = 1

#     n = len(arr)

#     if n < 2:
#         return True, True

#     prev = arr[0]
#     for i in range(1, n):
#         cur = arr[i]
#         if cur < prev:
#             return False, None
#         elif cur == prev:
#             is_unique = 0
#         prev = cur
#     return True, is_unique


# @cython.wraparound(False)
# @cython.boundscheck(False)
# def groupby_index(ndarray[idxvalue_t] index, ndarray labels):
#     cdef dict result = {}
#     cdef Py_ssize_t i, length
#     cdef list members
#     cdef object idx, key

#     length = len(index)

#     for i in range(length):
#         key = util.get_value_1d(labels, i)

#         if util._checknull(key):
#             continue

#         idx = index[i]
#         if key in result:
#             members = result[key]
#             members.append(idx)
#         else:
#             result[key] = [idx]

#     return result
