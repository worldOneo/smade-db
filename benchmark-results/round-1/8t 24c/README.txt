All benchmarks here performed on AWS `r7i.8xlarge` (32 Threads + 256 GB RAM)

Smade DB was:
```
./main -threads 16 -allocator-pages 100000
```

Dragonfly was:
```
dragonfly --num_shards <dyn> --conn_io_threads <dyn> --port 6700
```