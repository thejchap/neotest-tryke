from tryke import (
    describe as d,
    test as tst,
    expect as exp,
)


with d("Group"):
    @tst
    def fn():
        exp(1).to_equal(1)

    @tst("positional via alias")
    def fn_positional():
        exp(1).to_equal(1)

    @tst(name="kwarg via alias")
    def fn_named():
        exp(1).to_equal(1)

    @tst.skip("broken")
    def fn_skipped():
        exp(1).to_equal(2)


with d(name="KwargGroup"):
    @tst
    def fn_in_kwarg_group():
        exp(1).to_equal(1)


@tst.cases(a={"x": 1}, b={"x": 2})
def parametrized(x: int) -> None:
    exp(x).to_be_greater_than(0)


@tst.cases(
    tst.case("first", value=10),
    tst.case("second", value=20),
)
def typed_cases(value: int) -> None:
    exp(value).to_be_greater_than(0)
