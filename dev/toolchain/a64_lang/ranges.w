// Numbers near the edges, worked out the same way on both targets: round()
// either side of a half and at the ends of the integer range, a nan held in
// a region, float literals longer than a 63-bit mantissa, and -2^62 through
// number() and json.parse. The last line faulted on both before -2^62 was an
// integer, so it stays last.
import json
same(x)
    return x
out(round(0.49999999999999994))
out(round(0.5))
out(round(same(0.0) - 0.5))
out(round(4503599627370497.0))
out(round(same(0.0) - 4503599627370497.0))
out(round(4611686018427387392.0))
out(round(same(0.0) - 4611686018427387904.0))
n = same(0.0) / same(0.0)
a = array(2)
a[0] = n
a[1] = 1
b = array(2)
b[0] = n
b[1] = 1
out(a == b)
out(a == copy(a))
out(a <= b)
out(a > b)
g = same(1.5)
c = array(1)
c[0] = g
d = array(1)
d[0] = g
out(c == d)
out(c <= d)
out(c < d)
x = 9007199254740993.0000000000001
out(x - 9007199254740992.0)
out(123456789012345692161.0 == 123456789012345700352.0)
out(same(1.00000000000000011102230246251565404236316680908203125000001) == 1.0)
out(number("-4611686018427387904"))
out(number("-4611686018427387905"))
out(number("4611686018427387903"))
out(number("4611686018427387904"))
out(parse("[-4611686018427387904, -4611686018427387905, 4611686018427387903]"))
out(number("-4611686018427387904") % 3)
