// want: abc
keep(box, v)
    return 0
keep:after
    box[0] = v
    return true
arr = array(1)
t = copy("a")
t = t . "b"
t = t . "c"
keep(arr, t)
t = t . "d"
out(arr[0])
