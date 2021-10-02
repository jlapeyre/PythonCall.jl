"""
    pyiter(x)

Equivalent to `iter(x)` in Python.
"""
pyiter(x) = pynew(errcheck(@autopy x C.PyObject_GetIter(getptr(x_))))
export pyiter

"""
    unsafe_pynext(x)

Return the next item in the iterator `x`. When there are no more items, return NULL.
"""
unsafe_pynext(x::Py) = pynew(errcheck_ambig(C.PyIter_Next(getptr(x))))