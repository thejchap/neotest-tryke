from tryke import test as tst


def tst(fn):
    return fn


@tst
def shadowed_not_a_tryke_test():
    pass
