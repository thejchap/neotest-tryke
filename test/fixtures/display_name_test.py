from tryke import test, describe, expect


@test(name="basic equality")
def test_basic():
    expect(1).to_equal(1)


@test("positional name")
def test_positional():
    expect(True).to_be_truthy()


@test
def test_bare():
    expect(1).to_equal(1)


@test()
def test_no_name():
    expect(1).to_equal(1)


@test(name="named in group")
def test_in_group():
    expect(1).to_equal(1)
