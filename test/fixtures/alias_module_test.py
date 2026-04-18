import tryke as t


with t.describe("Channel"):
    @t.test
    def test_basic():
        t.expect(1 + 1).to_equal(2)

    @t.test(name="named through module alias")
    def test_named():
        t.expect(True).to_be_truthy()

    @t.test.skip("broken")
    def test_skipped():
        t.expect(1).to_equal(2)


@t.test.cases(
    zero={"n": 0, "squared": 0},
    one={"n": 1, "squared": 1},
)
def square(n: int, squared: int) -> None:
    t.expect(n * n).to_equal(squared)


@t.test.cases(
    t.test.case("my test", n=0, expected=0),
    t.test.case("2 + 3", n=5, expected=25),
)
def square_typed(n: int, expected: int) -> None:
    t.expect(n * n).to_equal(expected)
