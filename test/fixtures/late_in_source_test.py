from tryke_guard import __TRYKE_TESTING__


def production_fn() -> int:
    return 42


# Simulate a long production file — the tryke import sits well past the
# 50-line cutoff, tucked inside the `__TRYKE_TESTING__` guard.
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
if __TRYKE_TESTING__:
    from tryke import describe, expect, test

    with describe(name="late"):
        @test("works")
        def late_test() -> None:
            expect(production_fn()).to_equal(42)
