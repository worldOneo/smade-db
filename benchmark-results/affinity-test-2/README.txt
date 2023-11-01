All benchmarks here performed on one AWS `r7a.8xlarge` (32 Threads + 64 GB RAM) with threads=8 and connections=12

Smade DB was:
```
./main -threads <dyn> -allocator-pages 100000 -affinity-spacing <dyn>
```