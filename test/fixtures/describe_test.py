from tryke import test, describe


with describe("Math"):
    with describe("addition"):
        @test
        def test_add():
            assert 1 + 1 == 2

    with describe("subtraction"):
        @test
        def test_sub():
            assert 3 - 1 == 2


@test
def test_standalone():
    assert True
