from tryke import test


def add(a: int, b: int) -> int:
    """Add two numbers.

    >>> add(1, 2)
    3
    >>> add(0, 0)
    0
    """
    return a + b


def no_doctest(x: int) -> int:
    """Just a regular docstring."""
    return x


class Counter:
    """A simple counter.

    >>> c = Counter()
    >>> c.value
    0
    """

    def __init__(self) -> None:
        self.value = 0

    def increment(self) -> None:
        """Increment the counter.

        >>> c = Counter()
        >>> c.increment()
        >>> c.value
        1
        """
        self.value += 1

    def reset(self) -> None:
        """Reset - no doctest here."""
        self.value = 0


@test
def test_something():
    assert True
