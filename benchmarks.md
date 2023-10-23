# Get/Set benchmarks with memtier:

## Pipelined

1:1

`memtier_benchmark -s localhost -t 4 -c 12 -d 20 -n 1000000 --ratio=1:1 --key-minimum=1 --key-maximum=1000000 --hide-histogram --print-percentiles=50,80,99.9,99.99,99.995,99.99
9  --pipeline=8  -p {port}`

1:10

`memtier_benchmark -s localhost -t 4 -c 12 -d 20 -n 1000000 --ratio=1:10 --key-minimum=1 --key-maximum=1000000 --hide-histogram --print-percentiles=50,80,99.9,99.99,99.995,99.99
9  --pipeline=8  -p {port}`

## Not Pipelined

1:1

`memtier_benchmark -s localhost -t 4 -c 12 -d 20 -n 1000000 --ratio=1:1 --key-minimum=1 --key-maximum=1000000 --hide-histogram --print-percentiles=50,80,99.9,99.99,99.995,99.99
9  -p {port}`

1:10

`memtier_benchmark -s localhost -t 4 -c 12 -d 20 -n 1000000 --ratio=1:10 --key-minimum=1 --key-maximum=1000000 --hide-histogram --print-percentiles=50,80,99.9,99.99,99.995,99.99
9 -p {port}`
