from tryke_guard import __TRYKE_TESTING__


def production_fn(x: int) -> int:
    return x * 2


if __TRYKE_TESTING__:
    import tryke as t

    with t.describe(name="Channel"):
        @t.test
        def test_basic() -> None:
            t.expect(production_fn(2)).to_equal(4)
