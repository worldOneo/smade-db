All tests were performed on AWS `c7a.16xlarge` (64t/32c + 128GB RAM) with `AMD EPYC 9R14`

Crusher configured with:

```
threads=32
connections=6
crusher_thread_range=32-63
```

Atillery config:

```
const clients = 192
const requestsPerClient = 50_000

const minKey = 10_000_000
const maxKey = 99_999_999
const setPerTransaction = 5
```

Atillery used as:

```
GOMAXPROCS=32 taskset -c 32-63 ./atillery
```

Dragonfly somehow breaks down at 10+ Threads, need to investigate that.
It is not, that Dragonfly is slowing down, but some request take foreeeeever and the atillerys CPU usage drops.
The runs that have that symptom have been ran 3 times. (10, 12, 14, 16 threads)