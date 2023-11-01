All tests performed on AWS `c7i.12xlarge` with `Intel(R) Xeon(R) Platinum 8488C` (48 Threads + 96GB RAM)

Atillery:
```
const clients = 96
const requestsPerClient = 50_000

const minKey = 10_000_000
const maxKey = 99_999_999
const setPerTransaction = 5

const okBytes = 5
const queuedBytes = 9

const listHead = 2
```

Benchmark:
```
taskset -c 32-48 memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 1000000 --ratio=1:0 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port
taskset -c 32-48 memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 1000000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port --key-pattern G:G
taskset -c 32-48 memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 100000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 -p $port --key-pattern G:G
taskset -c 32-48 memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 1000000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 --pipeline=8  -p $port --key-pattern R:R
taskset -c 32-48 memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 100000 --ratio=1:10 --key-minimum=1 --key-maximum=100000000 --hide-histogram --print-percentiles=50,80,90,99,99.9,99.99,99.995,99.999,100 -p $port --key-pattern R:R
```
with threads=8 and connections=12