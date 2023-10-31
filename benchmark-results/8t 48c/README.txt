All benchmarks here performed on AWS `r7i.8xlarge` (32 Threads + 256 GB RAM)

Atillery was warmed up with:

```
memtier_benchmark -s localhost -t $threads -c $connections -d 20 -n 1000000 --ratio=1:0 --key-minimum=1 --key-maximum=100000000 --hide-histogram --pipeline=8  -p $port
```

Smade DB was:
```
./main -threads 16 -allocator-pages 100000
```

Dragonfly was:
```
dragonfly --num_shards <dyn> --conn_io_threads <dyn> --port 6700
```