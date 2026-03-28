from tryke import expect, test


@test("basic")
def test_basic():
    expect(expr=1 + 1, name="1 + 1").to_equal(other=2)
