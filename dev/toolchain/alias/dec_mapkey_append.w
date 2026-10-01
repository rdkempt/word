// want: ["abc"] 1
import txt
m = {}
t = copy("a")
t = t . "b"
t = t . "c"
m[decode(t)] = 1
t = t . "d"
out(keys(m) . " " . m["abc"])
