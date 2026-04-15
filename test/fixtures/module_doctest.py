"""Module with a doctest.

>>> 1 + 1
2
"""

from tryke import test


@test
def test_something():
    assert True
