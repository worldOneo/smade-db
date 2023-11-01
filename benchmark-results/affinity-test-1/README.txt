All benchmarks here performed on AWS `r7i.8xlarge` (32 Threads + 256 GB RAM) with threads=8 and connections=12

Smade DB was:
```
./main -threads <dyn> -allocator-pages 100000 -affinity-spacing <dyn>
```